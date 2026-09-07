# tailcat-bootstrap

在 Debian/Ubuntu 设备上安装 Tailcat 远程入口，需要 systemd，支持 amd64、arm64 和 ARMv7 armhf。

## 安装

在需要远程接入的现有用户下执行：

```bash
curl -fsSL https://raw.githubusercontent.com/geraldpeng6/tc/main/bootstrap-tailcat.sh | sudo bash
```

默认开机自启、故障自动重启，安装完成后显示设备 token。远程终端使用执行 `sudo` 的用户，沿用其现有权限。

默认使用内置售后公钥和公共中继 `derp1d.tailscale.com`，无需 Tailscale 账号或开放公网入站端口。公共中继不保证可用性，可通过 `--derp` 指定自建中继。

## 连接

在售后电脑将内置公钥对应的私钥保存为 Tailcat 的 `client-default`，然后执行：

```bash
tailcat ping <设备 token>
tailcat ssh <设备 token>
```

远程执行 `sudo` 时使用设备上该用户的密码。妥善保管售后私钥和设备密码。

## 常用操作

```bash
systemctl status tailcat-ssh       # 查看状态
sudo systemctl stop tailcat-ssh    # 停止服务
sudo systemctl start tailcat-ssh   # 启动服务
sudo journalctl -u tailcat-ssh     # 查看连接日志
```

需要传入参数时，先下载脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/geraldpeng6/tc/main/bootstrap-tailcat.sh -o bootstrap-tailcat.sh
sudo bash bootstrap-tailcat.sh --duration-minutes=120
```

临时窗口支持 5–1440 分钟，到期停止，不随开机启动；每次启动服务重新计时。再次不带参数运行安装器可恢复常驻模式。

覆盖售后公钥或中继：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:...'
sudo bash bootstrap-tailcat.sh --derp='derp.example.com'
```

重复运行会保留设备身份和 token，以及未指定的公钥和中继配置。`--allow` 替换整个公钥列表；已有设备更换中继需要卸载重装，生成新 token。更多参数见 `--help`。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/geraldpeng6/tc/main/bootstrap-tailcat.sh | sudo bash -s -- --uninstall
```

删除服务、设备私钥和 token。Tailcat 软件包保留，如需移除：

```bash
sudo dpkg --remove tailcat
```
