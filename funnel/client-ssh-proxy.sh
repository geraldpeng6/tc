#!/usr/bin/env bash
# ssh ProxyCommand：把 <host>-NNN 解析为 tailcat stdio 通道。
# 编号规则：NNN = tokens.jsonl 中该 host 倒数第 N 条 token
# （-001 = 最新，-002 = 次新……）；不带编号等价于 -001。
#
# ~/.ssh/config 配置：
#   Host cepi-*
#       ProxyCommand /path/to/client-ssh-proxy.sh %h
#       StrictHostKeyChecking accept-new
#       UserKnownHostsFile ~/.ssh/known_hosts_tailcat
#
# 环境变量：
#   TAILCAT_TOKENS_FILE  token 存储文件（默认 ~/.local/share/tailcat/tokens.jsonl）
#   TAILCAT_BIN          tailcat 二进制路径（默认 PATH 中的 tailcat）
set -euo pipefail

host="$1"
tokens_file="${TAILCAT_TOKENS_FILE:-$HOME/.local/share/tailcat/tokens.jsonl}"
tailcat_bin="${TAILCAT_BIN:-tailcat}"

base="${host%%-*}"
suffix="${host#"$base"}"
if [[ "$suffix" =~ ^-([0-9]+)$ ]]; then
    idx=$((10#${BASH_REMATCH[1]}))
else
    idx=1
fi

token="$(python3 - "$tokens_file" "$base" "$idx" <<'PY'
import json, sys
path, base, idx = sys.argv[1], sys.argv[2], int(sys.argv[3])
matches = []
try:
    with open(path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("host") == base:
                matches.append(r.get("token", ""))
except OSError:
    pass
print(matches[-idx] if 0 < idx <= len(matches) else "")
PY
)"

if [[ -z "$token" ]]; then
    echo "client-ssh-proxy: no token #$idx for host '$base' in $tokens_file" >&2
    exit 1
fi

exec "$tailcat_bin" "$token" 22
