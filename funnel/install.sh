#!/usr/bin/env bash
# tailcat 自动安装入口：自动探测可用 DERP 中继后调用官方 bootstrap。
# 部署时与 bootstrap-tailcat.sh 放在同一 HTTP 目录下，用环境变量
# TAILCAT_INSTALL_URL 指向自身地址（见 funnel/README.md）。
#   curl -fsSL <部署地址>/install.sh | sudo bash
#
# 行为：
#   - 首次安装：并行探测全部 Tailscale DERP 区域，选延迟最低且 /derp/probe
#     返回 200 的中继，传给 bootstrap --derp；全部不可达时回落 --public-derp。
#   - 已安装设备：中继已烧进设备身份，跳过探测，直接透传参数（幂等）。
#   - 显式 --derp / --public-derp / --uninstall / --help：跳过自动选路。
#   - --no-auto-derp：禁用自动选路，使用 bootstrap 内置默认中继。
#
# token 不回传：安装完成后由用户在设备上查看（终端文本/二维码）并手动转发。
#
# 其余参数原样透传给 bootstrap-tailcat.sh。

set -Eeuo pipefail
umask 077

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# Tailscale 官方 DERP 每区域一个代表节点（derpmap 2026-09 快照）。
readonly -a DERP_CANDIDATES=(
    derp1f.tailscale.com    # nyc  New York City
    derp2d.tailscale.com    # sfo  San Francisco
    derp3e.tailscale.com    # sin  Singapore
    derp4f.tailscale.com    # fra  Frankfurt
    derp5e.tailscale.com    # syd  Sydney
    derp6.tailscale.com     # blr  Bengaluru
    derp7e.tailscale.com    # tok  Tokyo
    derp8e.tailscale.com    # lhr  London
    derp9d.tailscale.com    # dfw  Dallas
    derp10b.tailscale.com   # sea  Seattle
    derp11e.tailscale.com   # sao  São Paulo
    derp12d.tailscale.com   # ord  Chicago
    derp13b.tailscale.com   # den  Denver
    derp14b.tailscale.com   # ams  Amsterdam
    derp15b.tailscale.com   # jnb  Johannesburg
    derp16b.tailscale.com   # mia  Miami
    derp17b.tailscale.com   # lax  Los Angeles
    derp18b.tailscale.com   # par  Paris
    derp19b.tailscale.com   # mad  Madrid
    derp20b.tailscale.com   # hkg  Hong Kong
    derp21b.tailscale.com   # tor  Toronto
    derp22b.tailscale.com   # waw  Warsaw
    derp23b.tailscale.com   # dbi  Dubai
    derp24b.tailscale.com   # hnl  Honolulu
    derp25b.tailscale.com   # nai  Nairobi
    derp26b.tailscale.com   # nue  Nuremberg
    derp27b.tailscale.com   # iad  Ashburn
    derp28b.tailscale.com   # hel  Helsinki
)


TMP_DIR=""
cleanup() { [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [bootstrap options]

自动安装入口：首次安装时并行探测全部 Tailscale DERP 区域，
自动选择延迟最低的可用中继；全部不可达时回落 Tailcat 公共中继。

额外选项：
  --no-auto-derp   禁用自动选路，使用 bootstrap 内置默认中继

其余参数（--allow / --derp / --public-derp / --duration-minutes /
--uninstall 等）原样透传给 bootstrap-tailcat.sh。

环境变量：
  TAILCAT_INSTALL_URL  入口自身 URL（决定 bootstrap 下载源；必填）
EOF
}

# probe_host <host> <result-file>
# 成功（HTTP 200）时写入 "<time_total> <host>"，失败不写文件。
probe_host() {
    local host="$1" out="$2" status time_total
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --proto '=https' --connect-timeout 3 --max-time 5 \
        "https://${host}/derp/probe" 2>/dev/null)" || return 0
    [[ "$status" == "200" ]] || return 0
    time_total="$(curl --silent --output /dev/null --write-out '%{time_total}' \
        --proto '=https' --connect-timeout 3 --max-time 5 \
        "https://${host}/derp/probe" 2>/dev/null)" || return 0
    [[ -n "$time_total" ]] || return 0
    printf '%s %s\n' "$time_total" "$host" >"$out"
}

# pick_derp <dir>：并行探测所有候选，输出延迟最低的 host；全部失败则无输出。
pick_derp() {
    local dir="$1" host
    mkdir -p "$dir"
    local -a pids=()
    for host in "${DERP_CANDIDATES[@]}"; do
        probe_host "$host" "${dir}/${host}" &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    # 每个结果文件一行 "<秒> <host>"，按耗时升序取第一行。
    sort -n "${dir}"/* 2>/dev/null | awk 'NR==1 {print $2}'
}

main() {
    local -a args=()
    local explicit_relay=0 no_auto=0 skip_probe=0

    while (($# > 0)); do
        case "$1" in
            --no-auto-derp) no_auto=1; shift ;;
            -h|--help)      skip_probe=1; args+=("$1"); shift ;;
            --uninstall)    skip_probe=1; args+=("$1"); shift ;;
            --derp=*|--public-derp)
                explicit_relay=1; args+=("$1"); shift ;;
            --derp)
                explicit_relay=1; args+=("$1"); shift
                (($# > 0)) && { args+=("$1"); shift; }
                ;;
            *) args+=("$1"); shift ;;
        esac
    done

    [[ "${EUID}" -eq 0 ]] || die "需要 root 运行：curl -fsSL <url>/install.sh | sudo bash"
    command -v curl >/dev/null || die "required command not found: curl"

    TMP_DIR="$(mktemp -d -t tailcat-install.XXXXXXXX)"

    # 与入口同源的官方 bootstrap 脚本。
    local self_url bootstrap_url bootstrap
    [[ -n "${TAILCAT_INSTALL_URL:-}" ]] \
        || die "未设置 TAILCAT_INSTALL_URL（入口自身 URL，如 https://<host>/install.sh）"
    self_url="${TAILCAT_INSTALL_URL}"
    bootstrap_url="${self_url%/*}/bootstrap-tailcat.sh"
    bootstrap="${TMP_DIR}/bootstrap-tailcat.sh"
    curl --fail --show-error --silent --location --max-time 180 \
        --output "$bootstrap" "$bootstrap_url" \
        || die "下载 bootstrap 失败: ${bootstrap_url}"

    if ((explicit_relay)); then
        log "使用显式指定的中继配置"
    elif ((no_auto)); then
        log "已禁用自动选路，使用 bootstrap 内置默认中继"
    elif ((skip_probe)); then
        : # --uninstall / --help：不做任何探测
    elif [[ -s "$KEY_FILE" ]]; then
        log "检测到已有设备身份，沿用已保存的中继（换中继需先 --uninstall）"
    else
        log "探测 ${#DERP_CANDIDATES[@]} 个 DERP 区域（约 5 秒）…"
        local best
        best="$(pick_derp "${TMP_DIR}/probe")"
        if [[ -n "$best" ]]; then
            log "选中最低延迟中继: ${best}"
            args+=("--derp" "$best")
        else
            warn "所有 Tailscale DERP 中继均不可达，回落 Tailcat 公共中继（best-effort）"
            args+=("--public-derp")
        fi
    fi

    local rc=0
    # bash 3.2 (macOS) + set -u: 空数组展开必须用 @+ 哨兵，否则报 unbound variable。
    bash "$bootstrap" "${args[@]+"${args[@]}"}" || rc=$?
    return "$rc"
}

main "$@"
