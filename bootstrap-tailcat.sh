#!/usr/bin/env bash
# ============================================================================
# tailcat 服务器端引导脚本
#
# 用途: 在一台全新的 Linux 机器上配置 tailcat, 使其可以从任何网络
#       通过 `tailcat ssh <user>@<token-or-dns>` 无端口暴露地 SSH 登录。
#
# 动作:
#   1. 安装 tailcat v0.3.0 (.deb, 自动识别 amd64/arm64/armv7)
#   2. 生成持久密钥 (--fixed-region, 令牌永久有效, 重启不变)
#   3. 安装 systemd 服务: --serve=no-auth-ssh + --allow 白名单
#      (无需 SSH 密钥/密码, 新机器零 SSH 配置)
#   4. 令牌写入 /var/lib/tailcat/token 并打印出来
#
# 安全模型(两层):
#   令牌公开无害(只是门牌号) → WireGuard 白名单(--allow, 需对应私钥才能握手)
#
# 用法:
#   bash bootstrap-tailcat.sh [选项]
# 选项:
#   --user NAME    用哪个系统用户跑服务 (默认: 当前用户)
#   --port N       兼容参数, 现已忽略(no-auth-ssh 模式)
#   --derp HOST    使用自建 DERP 中继 (可选, 默认用官方 tailcat.dev 免费中继)
#   --uninstall    卸载服务并删除密钥
#
# 安全模型:
#   认证完全依赖 --allow 白名单(需持有对应私钥才能握手),
#   无需配置 SSH 密钥/密码, 新机器零 SSH 配置
#   令牌(token)只是地址, 公开无风险
# ============================================================================

set -euo pipefail

TAILCAT_VERSION="0.3.0"
DOWNLOAD_BASE="https://github.com/tailscale/tailcat/releases/download/v${TAILCAT_VERSION}"

# ---- GitHub 加速代理链 (国内机器友好): 依次尝试, 8s 超时自动切换 ----
# 校验: 下载后用官方 checksums.txt 做 SHA256 校验, 防止代理链任何一环篡改
GH_PROXIES=(
    "https://gh-proxy.com"
    "https://ghfast.top"
    ""   # 空字符串 = 直连 GitHub, 兜底
)
CHECKSUM_URL="${DOWNLOAD_BASE}/checksums.txt"
TOKEN_FILE="/var/lib/tailcat/token"
SERVICE_NAME="tailcat-ssh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ---- 客户端白名单: 只允许持有对应私钥的设备连接 ----
# 这是一个【公钥】, 公开无风险(等同 SSH authorized_keys 里的一行)
# 对应的私钥文件只存在于你自己的设备上, 绝不要出现在本仓库
# 生成新设备身份: tailcat genkey --client --key=client-default
ALLOWED_CLIENT="nodekey:6381fe8fa9c2b67c7d25ded51bde5e39d8c29b55dcd9411a44ba1525ac2f543f"

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
SSH_PORT="22"
DERP_REGION=""
MODE="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)     SSH_PORT="$2"; shift 2 ;;
        --derp)     DERP_REGION="$2"; shift 2 ;;
        --user)     SSH_USER="$2"; shift 2 ;;
        --uninstall) MODE="uninstall"; shift ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)          echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------
log()  { echo -e "\033[1;32m[bootstrap]\033[0m $*"; }
warn() { echo -e "\033[1;33m[bootstrap]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[bootstrap] 错误:\033[0m $*" >&2; exit 1; }

need_root() {
    [[ $EUID -eq 0 ]] || die "请用 sudo 运行: sudo bash $0 $*"
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if [[ "$MODE" == "uninstall" ]]; then
    need_root "$@"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TOKEN_FILE"
    systemctl daemon-reload 2>/dev/null || true
    tailcat genkey --delete --key=default 2>/dev/null || true
    log "已卸载 ${SERVICE_NAME} (未删除 /usr/bin/tailcat 本体, 如需: apt remove tailcat)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
[[ -n "${SSH_USER:-}" ]] || SSH_USER="$(id -un)"

# 1. 架构检测
case "$(uname -m)" in
    x86_64)  DebArch="amd64" ;;
    aarch64) DebArch="arm64" ;;
    armv7l|armv6l) DebArch="armv7" ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac
log "架构: $(uname -m) → ${DebArch}"

command -v curl >/dev/null 2>&1 || apt-get update -y && apt-get install -y curl 2>/dev/null

# 代理感知的下载函数: 依次尝试代理链, 输出写到 $1
# 代理 URL 格式: https://gh-proxy.com/https://github.com/... (完整原始 URL 拼在后面)
fetch() {
    local out="$1" url="$2" p url_full ok=1
    for p in "${GH_PROXIES[@]}"; do
        if [[ -n "$p" ]]; then
            url_full="${p}/${url}"
        else
            url_full="${url}"
        fi
        if curl -fsSL --connect-timeout 8 -o "$out" "$url_full"; then
            return 0
        fi
        warn "下载失败: ${url_full}"
    done
    return 1
}

# 带 SHA256 校验的下载 .deb (防代理链篡改): fetch_deb <架构>
fetch_deb() {
    local arch="$1" deb="tailcat_${TAILCAT_VERSION}_linux_${arch}.deb"
    local sum
    # checksums.txt 同样走代理链拉取(与 deb 相同策略)
    for p in "${GH_PROXIES[@]}"; do
        sum="$( { [[ -n "$p" ]] && curl -fsSL --connect-timeout 8 "${p}/${CHECKSUM_URL}" || curl -fsSL --connect-timeout 8 "${CHECKSUM_URL}"; } \
            2>/dev/null | grep "${deb}" | awk '{print $1}')" && [[ -n "$sum" ]] && break
    done
    fetch /tmp/tailcat.deb "${DOWNLOAD_BASE}/${deb}"
    if [[ -n "$sum" ]]; then
        if ! echo "${sum}  /tmp/tailcat.deb" | sha256sum -c --quiet >/dev/null 2>&1; then
            rm -f /tmp/tailcat.deb
            die "SHA256 校验失败 (${deb}) — 可能被代理链篡改, 拒绝安装"
        fi
        log "SHA256 校验通过"
    else
        warn "⚠ 未获取到 checksum, 跳过完整性校验 (网络受限?)"
    fi
}

# 2. tailcat 是否已装 & 版本
if command -v tailcat >/dev/null 2>&1; then
    CURRENT="$(tailcat --version 2>/dev/null || echo unknown)"
    if [[ "$CURRENT" == *"$TAILCAT_VERSION"* ]]; then
        log "tailcat ${TAILCAT_VERSION} 已安装, 跳过下载"
    else
        warn "已安装版本: $CURRENT, 将升级/重装到 ${TAILCAT_VERSION}"
        fetch_deb "$DebArch"
        dpkg -i /tmp/tailcat.deb || { apt-get install -f -y; }
        rm -f /tmp/tailcat.deb
    fi
else
    log "下载并安装 tailcat ${TAILCAT_VERSION} (${DebArch})... (经代理链: ${GH_PROXIES[*]})"
    fetch_deb "$DebArch"
    dpkg -i /tmp/tailcat.deb || { apt-get update -y && apt-get install -f -y; }
    rm -f /tmp/tailcat.deb
fi
command -v tailcat >/dev/null 2>&1 || die "tailcat 安装失败"

# 3. 持久密钥: 已存在则复用, 不存在则生成(fixed-region 保证令牌重启后不变)
mkdir -p "$(dirname "$TOKEN_FILE")"
if [[ -s "$TOKEN_FILE" ]]; then
    TOKEN="$(cat "$TOKEN_FILE")"
    log "复用已有持久令牌: ${TOKEN:0:20}..."
else
    log "生成持久密钥 (--fixed-region)..."
    if [[ -n "$DERP_REGION" ]]; then
        TOKEN="$(tailcat genkey --fixed-region --region="$DERP_REGION" | grep -Eo '^tc[A-Za-z0-9_=-]+')"
    else
        TOKEN="$(tailcat genkey --fixed-region | grep -Eo '^tc[A-Za-z0-9_=-]+')"
    fi
    [[ -n "$TOKEN" ]] || die "生成密钥失败, 手动执行: tailcat genkey --fixed-region"
    echo "$TOKEN" > "$TOKEN_FILE"
    chmod 644 "$TOKEN_FILE"
fi

# 4. systemd 服务 (no-auth-ssh: 认证全靠 --allow 白名单, 无需 SSH 密钥)
log "写入 systemd 服务 (${SERVICE_NAME}, 白名单: ${ALLOWED_CLIENT:0:16}...)..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=tailcat ssh (via ${SSH_USER})
After=network-online.target
Wants=network-online.target

[Service]
Environment=TAILCAT_ADDR_FILE=${TOKEN_FILE}
ExecStart=$(command -v tailcat) --serve=no-auth-ssh --allow=${ALLOWED_CLIENT} --key=default
Restart=always
RestartSec=3
# 安全加固: 不给 root 权限, 不读系统敏感目录, 令牌文件单独可读
User=${SSH_USER}
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$(dirname "$TOKEN_FILE")

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 1
systemctl is-active --quiet "$SERVICE_NAME" \
    || { journalctl -u "$SERVICE_NAME" -n 20 --no-pager; die "服务启动失败"; }

# 5. 输出
log "════════════════════════════════════════════════════════"
echo   "  配置完成!"
echo   ""
echo   "  本机令牌 (永不过期, 重启不变):"
echo   "      $TOKEN"
echo   ""
echo   "  从 Mac 连接 (无需任何密码/密钥, 白名单已限定):"
echo   "      tailcat ssh ${SSH_USER}@$TOKEN"
echo   "      tailcat ssh ${SSH_USER}@$TOKEN 'uptime'   # 跑单命令"
echo   "      tailcat cp file.txt ${SSH_USER}@$TOKEN:   # 传文件"
echo   ""
echo   "  令牌即地址: 已保存在本机 $TOKEN_FILE"
echo   "  任何持白名单私钥的设备随时可连, 无需回传登记"
echo   ""
echo   "  查看状态: systemctl status ${SERVICE_NAME}"
echo   "  令牌文件: $TOKEN_FILE"
log "════════════════════════════════════════════════════════"