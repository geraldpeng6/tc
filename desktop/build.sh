#!/usr/bin/env bash
# 构建「请求技术支持」桌面入口离线捆绑 deb。
# 必须在带 dpkg-deb 的 Debian/Ubuntu 环境运行（本地或 CI）。
#
# 用法: ./build.sh [amd64|arm64|armv7] [版本号]
#   默认 amd64，默认版本见 DEFAULT_VERSION。
#   从 ../bootstrap-tailcat.sh 取引导脚本（需在 tc 仓库内构建）。
set -euo pipefail

cd "$(dirname "$0")"

readonly TAILCAT_VERSION="0.7.0"
readonly DEFAULT_VERSION="2.3.1"
readonly RELEASE_BASE="https://github.com/tailscale/tailcat/releases/download/v${TAILCAT_VERSION}"

readonly -A ASSET=(
    [amd64]="tailcat_0.7.0_linux_amd64.deb"
    [arm64]="tailcat_0.7.0_linux_arm64.deb"
    [armv7]="tailcat_0.7.0_linux_armv7.deb"
)
# 与 bootstrap-tailcat.sh 内固定的 EXPECTED_SHA256 保持一致
readonly -A BUNDLE_SHA256=(
    [amd64]="a8ad05230255186d9e8444ab8d7ebc8e7cca19283701404b49785531bf3c2af4"
    [arm64]="14e04174e8a6b27f9d5d0eccc3f986772456f2b2526c7bf8c1b71deec25cec7f"
    [armv7]="da6af712c448329edabe03fc6044cb6620f2b94cc3d3a1a5b25ea642fc20dce9"
)
readonly -A DPKG_ARCH=([amd64]=amd64 [arm64]=arm64 [armv7]=armhf)

arch="${1:-amd64}"
version="${2:-$DEFAULT_VERSION}"
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
