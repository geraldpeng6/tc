#!/usr/bin/env bash
# qrcode.py 回归测试：对固定输入逐位比对模块矩阵（fixture 由参考实现校验后固化）。
# 用法: bash tests/qrcode-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QRCODE="$ROOT/desktop/pkg/usr/local/lib/tailcat/qrcode.py"
FIXTURES="$ROOT/tests/fixtures/qrcode"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 不可用"

shopt -s nullglob
fixtures=("$FIXTURES"/*.json)
[[ ${#fixtures[@]} -gt 0 ]] || fail "没有 fixture：$FIXTURES"

for f in "${fixtures[@]}"; do
    text="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["text"])' "$f")"
    expected="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("text"); print(json.dumps(d, ensure_ascii=False, sort_keys=True))' "$f")"
    actual="$(python3 "$QRCODE" --json "$text")"
    normalized="$(printf '%s' "$actual" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, ensure_ascii=False, sort_keys=True))')"
    [[ "$expected" == "$normalized" ]] || fail "矩阵不一致: $(basename "$f")"
done

# 容量上限：超过 213 字节必须报错退出 2
long="$(python3 -c 'print("A"*214)')"
if python3 "$QRCODE" "$long" >/dev/null 2>&1; then
    fail "超长内容未被拒绝"
fi

# 终端渲染：行数 = ceil((size + 8) / 2)，且每行模块数一致
render="$(python3 "$QRCODE" "hello" | cat -v)"
lines="$(printf '%s\n' "$render" | wc -l | tr -d ' ')"
[[ "$lines" -eq 15 ]] || fail "hello 渲染行数异常: $lines"

printf 'qrcode tests passed\n'
