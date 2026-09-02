# tailcat-bootstrap

在 Debian/Ubuntu 系硬件上安装一个按需开启的 Tailcat 售后支持入口。它不开放公网入站端口，不需要 Tailscale 账号，也不会提供常驻 root shell。

Installer SHA256: `a3a3cdbc7d12b0d0d62ff6f2eecd4ef423cd9f7d492aec01187a95efe1139ba7`

## 安全模型

- Tailcat 固定为 `v0.4.0`，安装包按架构使用内置 SHA256 校验，校验缺失或不匹配立即退出。
- 服务固定运行于无 sudo 权限的 `tailcat-support` 账户；客户端填写的 SSH 用户名不会改变该账户。
- 首次安装必须传入设备专属的 Tailcat 客户端公钥。不要在整批设备上复用同一个客户端私钥。
- 服务不随开机启动。安装完成后开启一个默认 60 分钟的支持窗口，到期自动停止。
- `journalctl` 记录连接方 node key 和网络事件，但不记录完整 shell 命令。这不是命令级审计系统。
- 设备 token 不是认证密码，但包含设备公钥和中继信息，不应无必要地公开。

## 支持范围

- Debian、Ubuntu 及声明 `ID_LIKE=debian` 的发行版
- systemd
- `amd64`、`arm64`、ARMv7 `armhf`
- 不支持 ARMv6、RPM 发行版、非 systemd 容器

## 1. 为每台设备生成客户端身份

在售后人员的电脑安装同版本客户端：

```bash
go install github.com/tailscale/tailcat/cmd/tailcat@v0.4.0
```

每台设备生成不同的客户端私钥，并安全备份：

```bash
tailcat genkey --client --key=device-SERIAL
```

命令会打印 `nodekey:...` 公钥。公钥交给安装器；私钥只保存在受控的售后设备和加密备份中。

## 2. 客户一行安装

发布签名 tag `bootstrap-v1.0.0` 后，将 `nodekey:...` 和自建 DERP 域名替换为该设备的值。整条命令应通过产品说明书、签名发布页或其他独立可信渠道交付：

```bash
( f=$(mktemp) && curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 https://raw.githubusercontent.com/geraldpeng6/tc/bootstrap-v1.0.0/bootstrap-tailcat.sh -o "$f" && printf '%s  %s\n' 'a3a3cdbc7d12b0d0d62ff6f2eecd4ef423cd9f7d492aec01187a95efe1139ba7' "$f" | sha256sum --check --status - && sudo bash "$f" --allow='nodekey:DEVICE_SPECIFIC_PUBLIC_KEY' --derp='derp.example.com'; rc=$?; [ -z "${f:-}" ] || rm -f "$f"; exit "$rc" )
```

公开 Tailcat DERP 仅适合测试或无 SLA 场景，必须显式选择：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:DEVICE_SPECIFIC_PUBLIC_KEY' --public-derp
```

Tailcat 官方明确说明公共 DERP 有速率限制、无可用性承诺，并可能随时停止服务。商业售后应使用自建 DERP，并保留其他恢复通道。

## 3. 连接和结束支持

安装器会打印该设备的 `tc...` token。使用生成该设备客户端身份时采用的 key 名连接：

```bash
tailcat --key=device-SERIAL ping DEVICE_TOKEN
tailcat --key=device-SERIAL ssh DEVICE_TOKEN
tailcat --key=device-SERIAL cp diagnostics.txt DEVICE_TOKEN:/var/lib/tailcat/work/
```

只有授权客户端的 `ping` 成功，才证明中继、allowlist 和实际网络路径可用。`systemctl active` 只证明本机进程仍在运行。

支持窗口控制：

```bash
sudo systemctl stop tailcat-ssh   # 客户可随时关闭
sudo systemctl start tailcat-ssh  # 再开启同样时长的窗口
sudo journalctl -u tailcat-ssh    # 查看连接记录
```

安装时可把窗口设为 5 至 1440 分钟：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:...' --derp='derp.example.com' --duration-minutes=120
```

## 轮换和撤销售后密钥

生成新的设备专属客户端 key，然后在设备上重新运行已校验的安装器。新的 `--allow` 列表会完整替换旧列表并重启支持窗口：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:NEW_PUBLIC_KEY'
```

多个售后人员可以使用逗号分隔的公钥。每个人使用独立 key，离职或丢失设备时从列表移除：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:TECH_A,nodekey:TECH_B'
```

重跑时省略 relay 参数会保留服务器身份。不能在不更换服务器身份和 token 的情况下切换 DERP；安装器会拒绝这种隐式变化。

## 旧版迁移

旧脚本可能把私钥写在 `/root/.config/tailcat/keys/default.private.json`，token 写在 `/var/lib/tailcat/token`。新脚本在两者同时存在时会迁移私钥，并在服务实际发布的 token 与旧 token 一致后才删除旧副本：

```bash
sudo bash bootstrap-tailcat.sh --allow='nodekey:DEVICE_SPECIFIC_PUBLIC_KEY'
```

迁移时不要传 `--derp` 或 `--public-derp`，因为旧状态没有可信 relay 元数据。私钥或 token 只有一个存在时，脚本会停止并要求人工恢复，不会静默创建新身份。

## 卸载

```bash
sudo bash bootstrap-tailcat.sh --uninstall
```

卸载会删除 systemd 服务、设备私钥、token，以及由安装器创建的支持账户。设备 token 随即永久失效。Tailcat 软件包会保留，必要时运行 `sudo dpkg --remove tailcat`。

## 发布要求

客户执行的是 root 安装器，发布链路必须与代码同等审查：

1. `main` 开启分支保护，要求 CI 通过，禁止直接 push。
2. CI 通过后创建并推送签名 tag `bootstrap-v1.0.0`，且发布后不得移动该 tag。
3. 发布提交和版本 tag 使用受验证的签名。
4. 每次修改脚本后更新本页的 SHA256；把最终命令和哈希通过独立渠道交付。
5. 在干净的 Debian/Ubuntu 设备上验证安装、重启、窗口超时、密钥轮换、旧版迁移和卸载。

Tailcat 本身不承诺 CLI 或 wire format 稳定性。升级版本时必须同时验证服务端和售后客户端，不能只修改版本号。
