# funnel — 安装入口静态分发

把 tailcat 安装入口挂到公网（如 Tailscale Funnel），设备一行命令完成：
自动选 DERP 中继 → 安装服务。**token 不回传**：安装完成后由用户在设备上
查看（终端文本/二维码）并手动转发给技术人员。

## 组成

| 文件 | 作用 |
| --- | --- |
| `install.sh` | 设备侧入口。并行探测全部 Tailscale DERP 区域选最低延迟中继，调用同目录的 `bootstrap-tailcat.sh` |
| `server.py` | 服务端。仅 GET 静态文件；无任何上传/读取接口 |

## 部署（Tailscale Funnel 示例）

```
funnel/
├── server.py            # 本文件
├── site/                # TAILCAT_SITE_DIR：对外静态目录
│   ├── index.html
│   ├── install.sh       # 本目录 install.sh 的副本
│   └── bootstrap-tailcat.sh   # 仓库根目录同名文件的副本
└── logs/access.log
```

```bash
# 1. 启动后端（仅监听 localhost，由 funnel 转发）
TAILCAT_SITE_DIR=$PWD/site python3 server.py &

# 2. 挂 funnel
tailscale funnel --bg --https=443 http://127.0.0.1:8090
```

设备侧使用（入口 URL 必须显式注入，脚本内不硬编码部署地址）：

```bash
curl -fsSL https://<host>.ts.net/install.sh | \
  sudo TAILCAT_INSTALL_URL="https://<host>.ts.net/install.sh" bash
```

## install.sh 环境变量

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `TAILCAT_INSTALL_URL` | 无（必填） | 入口自身 URL，决定 bootstrap 下载源 |

## install.sh 额外参数

- `--no-auto-derp`：禁用自动选路，用 bootstrap 内置默认中继
- 其余参数（`--allow` / `--derp` / `--public-derp` / `--duration-minutes` / `--uninstall`）透传给 bootstrap
