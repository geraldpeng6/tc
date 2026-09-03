# tailcat-bootstrap

在 Debian/Ubuntu 系硬件上安装一个 Tailcat 远程入口。不开放公网入站端口，不需要 Tailscale 账号。

**默认为常驻模式**：服务开机自启、崩溃自动重启、令牌永不过期，机器重启后无需任何人到场即可远程接入。需要临时性窗口时使用 `--duration-minutes`。

Installer SHA256: `e3d72d63b8f222e002bb8f4d8dd460ca81c7553823aae435146f243be36b87fd`

## 一行安装

```bash
curl -fsSL https://raw.githubusercontent.com/geraldpeng6/tc/bootstrap-v1.1.1/bootstrap-tailcat.sh | sudo bash
```

安装器默认使用内置的售后客户端公钥和 `derp1d.tailscale.com`，并打印设备的 `tc...` token。

## 权限模型

- 默认安装**常驻服务**：`Restart=on-failure` + 开机自启，令牌永久有效。
- Tailcat 服务使用执行 `sudo` 的现有登录用户，不会创建 `tailcat-support` 用户。
- 远程终端拥有该用户本来的文件、设备组和 sudo 权限。该用户原本能 sudo 时，可在远程终端输入该用户自己的密码运行 `sudo`；安装器不会保存密码或修改 sudoers。
- 允许 sudo 意味着取得售后私钥和 sudo 密码的人可以完全控制设备。售后私钥和设备密码不能公开或共用泄漏。
- `journalctl` 记录连接方 node key 和网络事件，但不记录完整 shell 命令。

`derp1d.tailscale.com` 是测试用公共 DERP，没有商业可用性承诺。正式售后应改为自建 DERP。

## 连接

在售后电脑把内置公钥对应的私钥保存为 Tailcat 的 `client-default`，然后连接：

```bash
tailcat ping <设备 token>
tailcat ssh <设备 token>
```

进入远程终端后：

```bash
whoami
sudo -v
sudo <维修命令>
```

`sudo` 验证的是 `whoami` 显示用户的密码，不是一个通用的 root 密码。

## 常驻 vs 临时窗口

默认（无参数）安装常驻服务：

```bash
sudo bash bootstrap-tailcat.sh          # 常驻: 开机自启 + 自动重启
```

需要限时窗口（如给外部支持人员临时开门）时加 `--duration-minutes`，5 至 1440 分钟：

```bash
sudo bash bootstrap-tailcat.sh --duration-minutes=120
```

限时模式下服务不随开机启动，到期自动断开；每次 `systemctl start` 都重新开启同样时长的窗口。两种模式下设备身份（token）都保持不变。

## 状态与控制

```bash
systemctl status tailcat-ssh        # 查看状态
sudo systemctl stop tailcat-ssh     # 立即关闭入口
sudo systemctl start tailcat-ssh    # 重新打开
sudo journalctl -u tailcat-ssh      # 连接日志
```

## 覆盖默认配置

默认公钥和 DERP 仍可覆盖：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:...' --derp='derp.example.com'
sudo bash bootstrap-tailcat.sh --allow='nodekey:...' --public-derp
```

重复运行且不传这些参数时，会保留设备上已经保存的公钥列表、DERP、设备身份和 token。传入新的 `--allow` 会完整替换旧列表。

## 兼容和卸载

- 支持 Debian、Ubuntu、systemd，以及 `amd64`、`arm64`、ARMv7 `armhf`。
- 不支持 ARMv6、RPM 发行版和非 systemd 容器。
- 从 `bootstrap-v1.0.0` 升级时会删除旧安装器创建的 `tailcat-support` 系统用户，改用本次执行 `sudo` 的登录用户。

```bash
curl -fsSL https://raw.githubusercontent.com/geraldpeng6/tc/bootstrap-v1.1.1/bootstrap-tailcat.sh | sudo bash -s -- --uninstall
```

卸载会删除服务、设备私钥和 token，但不会删除或修改原登录用户。Tailcat 软件包会保留，必要时运行 `sudo dpkg --remove tailcat`。

## 发布要求

客户会以 root 执行此脚本，因此每次修改都必须通过 CI、发布新的不可移动 tag，并在干净设备上验证安装、远程登录、sudo、重启窗口、升级和卸载。不能移动已经发布的 tag。
