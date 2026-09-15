# funnel — 自动安装入口 + token 回传

把 tailcat 安装入口挂到公网（如 Tailscale Funnel），设备一行命令完成：
自动选 DERP 中继 → 安装常驻服务 → token 自动回传到本服务，无需用户转发。

## 组成

| 文件 | 作用 |
| --- | --- |
| `install.sh` | 设备侧入口。并行探测全部 Tailscale DERP 区域选最低延迟中继，调用同目录的 `bootstrap-tailcat.sh`；成功后把 token POST 回 `<入口>/api/token` |
| `server.py` | 服务端。GET 静态文件 + `POST /api/token` 写入 `data/tokens.jsonl`；无读取接口 |

## 部署（Tailscale Funnel 示例）

```
funnel/
├── server.py            # 本文件
├── site/                # TAILCAT_SITE_DIR：对外静态目录
│   ├── index.html
│   ├── install.sh       # 本目录 install.sh 的副本
│   └── bootstrap-tailcat.sh   # 仓库根目录同名文件的副本
├── secrets/upload-key   # 随机密钥：openssl rand -hex 24
├── data/tokens.jsonl    # 自动创建，token 落这里
└── logs/access.log
```

```bash
# 1. 生成 upload key（部署机和 install.sh 用同一把）
openssl rand -hex 24 > secrets/upload-key

# 2. 启动后端（仅监听 localhost，由 funnel 转发）
TAILCAT_SITE_DIR=$PWD/site \
TAILCAT_UPLOAD_KEY_FILE=$PWD/secrets/upload-key \
python3 server.py &

# 3. 挂 funnel
tailscale funnel --bg --https=443 http://127.0.0.1:8090
```

设备侧使用（upload key 通过环境变量注入，不写进公开脚本）：

```bash
curl -fsSL https://<host>.ts.net/install.sh | \
  sudo TAILCAT_UPLOAD_KEY="$(cat secrets/upload-key)" bash
```

> 注意：`curl | sudo bash` 管道形式下 `sudo` 默认不保留环境变量。
> 需要回传时改用 `sudo -E bash`，或把 key 直接写进部署用的
> install.sh 副本（upload key 仅有追加写权限，无读取能力，
> 公开的风险是垃圾提交，可接受）。

## 读取 token

token 只落部署机本地，无网络读取接口：

```bash
cat data/tokens.jsonl
# {"ts":…,"time":"…","token":"tc…","host":"设备主机名","ip":"来源IP"}
```

## install.sh 环境变量

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `TAILCAT_INSTALL_URL` | 内置 funnel 地址 | 入口自身 URL，决定 bootstrap 下载源与默认上传地址 |
| `TAILCAT_UPLOAD_URL` | `<入口目录>/api/token` | 覆盖 token 回传地址 |
| `TAILCAT_UPLOAD_KEY` | 空 | 上传密钥；为空则跳过回传 |

## install.sh 额外参数

- `--no-auto-derp`：禁用自动选路，用 bootstrap 内置默认中继
- `--no-upload`：安装成功后不回传 token
- 其余参数（`--allow` / `--derp` / `--public-derp` / `--duration-minutes` / `--uninstall`）透传给 bootstrap
