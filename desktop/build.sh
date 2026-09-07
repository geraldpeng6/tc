#!/usr/bin/env bash
# 构建「请求技术支持」桌面入口离线捆绑 deb。
# 必须在带 dpkg-deb 的 Debian/Ubuntu 环境运行（本地或 CI）。
#
# 用法: ./build.sh [amd64|arm64|armv7] [版本号]
#   默认 amd64，默认版本 2.0.0。
#   从 ../bootstrap-tailcat.sh 取引导脚本（需在 tc 仓库内构建）。
set -euo pipefail

cd "$(dirname "$0")"

readonly TAILCAT_VERSION="0.4.0"
readonly DEFAULT_VERSION="2.0.0"
readonly RELEASE_BASE="https://github.com/tailscale/tailcat/releases/download/v${TAILCAT_VERSION}"

readonly -A ASSET=(
    [amd64]="tailcat_0.4.0_linux_amd64.deb"
    [arm64]="tailcat_0.4.0_linux_arm64.deb"
    [armv7]="tailcat_0.4.0_linux_armv7.deb"
)
# 与 bootstrap-tailcat.sh 内固定的 EXPECTED_SHA256 保持一致
readonly -A BUNDLE_SHA256=(
    [amd64]="38ff4b45fe56b32c75738c10dfed4f0b68d33bee49a19695f4bb9f9ec5d6e3c0"
    [arm64]="8f1835a3522ecfc855c9f4ece51c2266781fd03ce76da48036b08c4b86193899"
    [armv7]="e98c18862ee1c72ad85db6653b64fdda4fbf6d14980b96f4ada63e09e2456187"
)
readonly -A DPKG_ARCH=([amd64]=amd64 [arm64]=arm64 [armv7]=armhf)

arch="${1:-amd64}"
version="${2:-2.0.0}"
[[ -n "${ASSET[$arch]:-}" ]] || { echo "不支持的架构: $arch（可选 amd64/arm64/armv7）" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. 组装打包树
cp -a pkg "$work/pkg"
sed -e "s|@ARCH@|${DPKG_ARCH[$arch]}|" -e "s|@VERSION@|${version}|" \
    pkg/DEBIAN/control.template > "$work/pkg/DEBIAN/control"
rm "$work/pkg/DEBIAN/control.template"

install -m 0755 ../bootstrap-tailcat.sh "$work/pkg/usr/local/bin/bootstrap-tailcat"

# 2. 下载并校验捆绑的离线 deb
mkdir -p "$work/pkg/usr/local/share/tailcat"
bundle="$work/pkg/usr/local/share/tailcat/${ASSET[$arch]}"
echo "下载 ${ASSET[$arch]} …"
curl -fsSL --retry 2 --retry-delay 1 -o "$bundle" "${RELEASE_BASE}/${ASSET[$arch]}"
echo "${BUNDLE_SHA256[$arch]}  $bundle" | sha256sum --check --status \
    || { echo "SHA256 校验失败: ${ASSET[$arch]}" >&2; exit 1; }

# 3. 权限（DEBIAN 控制文件不带执行位，维护者脚本/程序 0755，sudoers 0440）
chmod 0755 "$work/pkg/DEBIAN/postinst" \
           "$work/pkg/DEBIAN/postrm" \
           "$work/pkg/usr/local/bin/tailcat-privileged" \
           "$work/pkg/usr/local/bin/tailcat-launcher" \
           "$work/pkg/usr/local/bin/bootstrap-tailcat"
chmod 0440 "$work/pkg/etc/sudoers.d/tailcat-desktop"

# 4. 构建
dpkg-deb --build --root-owner-group "$work/pkg" \
    "tailcat-desktop_${version}_${DPKG_ARCH[$arch]}.deb"
