# tailcat-bootstrap

一键把一台 Linux 机器变成可用 `tailcat ssh <user>@<token>` 从任何网络直连的服务器。
无需开放入站端口、无需 Tailscale 账号、无需修改路由表。

基于 [tailscale/tailcat](https://github.com/tailscale/tailcat)。

## 使用

在**全新 Linux 机器**上（需要 sudo）：

```bash
curl -fsSL https://raw.githubusercontent.com/<你>/<repo>/main/bootstrap-tailcat.sh -o bt.sh
sudo bash bt.sh
```

结尾会打印这台机器的**永久令牌** `tc...`，记下来。然后在你的笔记本上：

```bash
tailcat ssh <user>@<令牌>
```

完成。

## 选项

```bash
sudo bash bt.sh --port 22          # 指定后端 sshd 端口（默认 22）
sudo bash bt.sh --derp derp.example.com   # 自建 DERP 中继（国内建议）
sudo bash bt.sh --uninstall        # 卸载服务并删除密钥
```

## 它做了什么

1. 安装 tailcat v0.3.0（自动识别 amd64 / arm64 / armv7）
2. 生成持久密钥（`--fixed-region`，令牌重启不变）
3. 安装 systemd 服务：`--serve=22 --allow=<白名单公钥>`
   - WireGuard 白名单：只有持对应私钥的设备能握手
   - 真 sshd：还要通过系统 SSH 公钥认证（双层防护）

## 安全说明

- 仓库里的 `nodekey:...` 是**公钥**（等同 authorized_keys 里的一行），公开无风险
- **私钥只存在于你自己的设备上**，本仓库不含任何私钥或服务器令牌
- 服务器令牌（`tc...`）公开无害，只是"门牌号"；没有客户端私钥连握手都过不去
- 误泄露令牌时：换一台中继重新 `genkey --fixed-region` 得到全新令牌，旧令牌作废

## 客户端（笔记本）准备

```bash
go install github.com/tailscale/tailcat/cmd/tailcat@latest
tailcat genkey --client --key=client-default
# 把打印出的 nodekey:... 填入脚本的 ALLOWED_CLIENT
```