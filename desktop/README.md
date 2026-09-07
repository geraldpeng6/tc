# desktop — 请求技术支持（桌面/应用入口）

把 tailcat 远程支持包装成用户可直接打开的形态：应用列表/桌面双击即可
**按需开启限时远程支持**（1–24 小时，默认 2 小时，到期自动关闭），
全程无需联网下载、无需重复输入密码，结束界面用中文引导用户把设备码
发给技术人员。

## 形态

| 文件 | 作用 |
| --- | --- |
| `pkg/usr/local/bin/bootstrap-tailcat.sh` | tc 仓库官方引导脚本（构建时原样打入，不修改） |
| `pkg/usr/local/bin/tailcat-privileged` | root 包装器（sudoers 唯一白名单项）：安装捆绑 deb 后调用引导脚本 |
| `pkg/usr/local/bin/tailcat-launcher` | 用户入口：问授权时长 → 免密/授权执行 → 中文摘要（设备码 + 可关窗提示） |
| `pkg/etc/sudoers.d/tailcat-desktop` | 免密白名单，只放行 root-owned 的 `tailcat-privileged` |
| `pkg/usr/share/applications/remote-support.desktop` | 应用列表/桌面入口（Name=请求技术支持） |
| `pkg/usr/local/share/tailcat/tailcat_*.deb` | 构建时下载的 tailcat 离线安装包（SHA256 与引导脚本内固定值一致） |

行为要点：

- 未安装 → 离线装 tailcat + 配置常驻服务；已安装 → 恢复常驻并显示设备码。
- 限时模式（`--duration-minutes=N`）：服务 `active` 但 `static`，到期自动停止，
  不随开机启动；重新打开程序并再次授权即重新计时/延长。
- 设备码（token）持久于 `/var/lib/tailcat/`，临时/常驻切换与重复执行均不变；
  仅 `--uninstall` 或更换 `--derp` 会生成新 token。
- 引导脚本默认会探测 DERP 中继连通性：设备完全无网时会明确报错
  （远程支持依赖 DERP，离线捆绑解决的是"下载安装包"环节）。

## 构建

在 Debian/Ubuntu（需要 `dpkg-deb`、`curl`、`sha256sum`）上运行，支持 amd64/arm64/armv7：

```bash
./build.sh [amd64|arm64|armv7] [版本号]
# 例：./build.sh arm64 2.0.0 → tailcat-desktop_2.0.0_arm64.deb
```

构建脚本从 tailscale 官方 release 下载对应架构的 tailcat deb 并按
`BUNDLE_SHA256`（与 `bootstrap-tailcat.sh` 内固定值一致）校验后捆绑。

## 安装

```bash
sudo dpkg -i tailcat-desktop_<版本>_<架构>.deb
```

安装即把入口装进应用列表（应用列表入口无需任何信任确认），并复制到
每个真实用户的桌面目录（`xdg-user-dir DESKTOP`，含中文 locale 的
`~/桌面`）。桌面图标首次双击时 GNOME 会提示"不受信任"，用户右键 →
"允许启动"一次即永久生效。

## 预装（出厂镜像）

```bash
# 在镜像构建 chroot / rootfs 中（用户已创建）：
sudo dpkg -i tailcat-desktop_<版本>_<架构>.deb
```

- 用户已存在 → postinst 直接放好图标；首次双击右键"允许启动"一次。
- 用户后创建（firstboot 建用户）→ 图标未覆盖到该用户；如需兜底，
  在 firstboot 建用户后重跑 `dpkg --configure tailcat-desktop`，
  或手动复制 `/usr/share/applications/remote-support.desktop` 到其桌面。
- 无桌面的系统（如 headless 龙虾派）：图标自然空转，
  用户入口为 shell 里的 `tailcat-launcher`。

## 卸载

```bash
sudo dpkg --purge tailcat-desktop        # postrm 会清理所有用户桌面的入口图标
sudo /usr/local/bin/bootstrap-tailcat --uninstall   # 移除服务、设备身份与设备码
```

## 适用系统

- Ubuntu/Debian 桌面（GNOME）：完整体验（应用列表 + 桌面图标；
  桌面图标首次需右键"允许启动"一次，应用列表入口无需）。
- Debian 最小安装（如龙虾派，Debian 13 arm64 + zutty）：无桌面环境时
  桌面图标自然空转，用户可在 shell 直接运行 `tailcat-launcher`；
  `Terminal=true` 走 `x-terminal-emulator`（zutty 已提供）。
- 无 pkexec 的系统自动回落终端 sudo；sudoers 白名单在则全程免密。
