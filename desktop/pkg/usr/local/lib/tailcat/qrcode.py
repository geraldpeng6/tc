#!/usr/bin/env python3
"""零依赖二维码生成器：字节模式 + 纠错等级 M，版本 1-10（≤213 字节）。

用法：
    qrcode.py <text>         在终端打印二维码（半块字符 + ANSI 颜色，深色=黑/浅色=白）
    qrcode.py --json <text>  输出模块矩阵 JSON（1=深色，含静区前原始矩阵，供测试比对）

仅用标准库；mask 按 ISO 18004 惩罚规则自动选取。
"""

import json
import sys

# ---- GF(256)（本原多项式 0x11d）----
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _gmul(a, b):
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_generator(degree):
    g = [1]
    for i in range(degree):
        ng = [0] * (len(g) + 1)
        for j, c in enumerate(g):
            ng[j] ^= _gmul(c, _EXP[i])
            ng[j + 1] ^= c
        g = ng
    return g


def _rs_encode(data, degree):
    g = _rs_generator(degree)          # 升幂：g[0]=x^0 … g[degree]=x^degree（首 1）
    div = g[-2::-1]                    # 去掉首 1 后按最高次优先排列
    rem = [0] * degree
    for b in data:
        factor = b ^ rem[0]
        rem = rem[1:] + [0]
        for j in range(degree):
            rem[j] ^= _gmul(div[j], factor)
    return rem


# ---- 版本表（等级 M）：(每块 ECC 码字, 组1块数, 组1数据码字, 组2块数, 组2数据码字) ----
_ECC_M = {
    1: (10, 1, 16, 0, 0),
    2: (16, 1, 28, 0, 0),
    3: (26, 1, 44, 0, 0),
    4: (18, 2, 32, 0, 0),
    5: (24, 2, 43, 0, 0),
    6: (16, 4, 27, 0, 0),
    7: (18, 4, 31, 0, 0),
    8: (22, 2, 38, 2, 39),
    9: (22, 3, 36, 2, 37),
    10: (26, 4, 43, 1, 44),
}
_ALIGN = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30],
    6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
}
_REMAINDER_BITS = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0}
MAX_BYTES = 213  # v10-M 字节模式容量


def _capacity_bytes(version):
    ecc, g1b, g1d, g2b, g2d = _ECC_M[version]
    total_data = g1b * g1d + g2b * g2d
    count_bits = 16 if version >= 10 else 8
    return (total_data * 8 - 4 - count_bits) // 8


def _pick_version(nbytes):
    for v in range(1, 11):
        if nbytes <= _capacity_bytes(v):
            return v
    raise ValueError(f"内容过长：{nbytes} 字节 > 支持上限 {MAX_BYTES} 字节")


def _bits_of(value, n):
    return [(value >> i) & 1 for i in range(n - 1, -1, -1)]


def _encode_codewords(data, version):
    ecc_per_block, g1b, g1d, g2b, g2d = _ECC_M[version]
    total_data = g1b * g1d + g2b * g2d
    bits = [0, 1, 0, 0] + _bits_of(len(data), 16 if version >= 10 else 8)
    for b in data:
        bits += _bits_of(b, 8)
    bits += [0] * min(4, total_data * 8 - len(bits))          # 终结符
    bits += [0] * (-len(bits) % 8)                            # 字节对齐
    cw = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pads = 0
    while len(cw) < total_data:            # 填充从 0xEC 起，EC/11 交替
        cw.append(0xEC if pads % 2 == 0 else 0x11)
        pads += 1
    blocks, eccs = [], []
    pos = 0
    for n in [g1d] * g1b + [g2d] * g2b:
        blocks.append(cw[pos:pos + n])
        eccs.append(_rs_encode(blocks[-1], ecc_per_block))
        pos += n
    out = []
    for i in range(max(map(len, blocks))):
        for b in blocks:
            if i < len(b):
                out.append(b[i])
    for i in range(ecc_per_block):
        for e in eccs:
            out.append(e[i])
    return out


def _bch_format(level_bits, mask_id):
    v = (level_bits << 3) | mask_id
    r = v << 10
    while r.bit_length() >= 11:               # 生成多项式 0x537 最高位为 bit10
        r ^= 0x537 << (r.bit_length() - 11)
    return ((v << 10) | r) ^ 0x5412


def _bch_version(version):
    r = version << 12
    while r.bit_length() >= 13:               # 生成多项式 0x1F25 最高位为 bit12
        r ^= 0x1F25 << (r.bit_length() - 13)
    return (version << 12) | r


# format info 第一副本位置：bit14 → bit0（(row, col)）
_FORMAT_SEQ = [
    (8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
    (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8),
]


def _build_matrix(data, version, mask_id):
    size = 17 + 4 * version
    m = [[None] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def set_fn(r, c, dark):
        m[r][c] = bool(dark)
        fn[r][c] = True

    # finder + 分隔符
    for r0, c0 in ((0, 0), (0, size - 7), (size - 7, 0)):
        for i in range(-1, 8):
            for j in range(-1, 8):
                ri, cj = r0 + i, c0 + j
                if not (0 <= ri < size and 0 <= cj < size):
                    continue
                inside = 0 <= i <= 6 and 0 <= j <= 6
                dark = inside and (i in (0, 6) or j in (0, 6)
                                   or (2 <= i <= 4 and 2 <= j <= 4))
                set_fn(ri, cj, dark)

    # timing
    for i in range(8, size - 8):
        set_fn(6, i, i % 2 == 0)
        set_fn(i, 6, i % 2 == 0)

    # alignment（与 finder 重合的角点除外；timing 线上的照常绘制并覆盖 timing）
    centers = _ALIGN[version]
    finder_centers = {(6, 6), (6, size - 7), (size - 7, 6)}
    for ri in centers:
        for ci in centers:
            if (ri, ci) in finder_centers:
                continue
            for i in range(-2, 3):
                for j in range(-2, 3):
                    set_fn(ri + i, ci + j, max(abs(i), abs(j)) != 1)

    # format info（两副本 + 固定暗模块）
    fmt = _bch_format(0b00, mask_id)
    for idx, (r, c) in enumerate(_FORMAT_SEQ):
        set_fn(r, c, (fmt >> (14 - idx)) & 1)
    for i in range(8):                       # bit0-7：第 8 行右段
        set_fn(8, size - 1 - i, (fmt >> i) & 1)
    for i in range(8, 15):                   # bit8-14：第 8 列下段
        set_fn(size - 15 + i, 8, (fmt >> i) & 1)
    set_fn(size - 8, 8, True)

    # version info（v7+，两副本，LSB 先放）
    if version >= 7:
        vbits = _bch_version(version)
        for i in range(18):
            bit = (vbits >> i) & 1
            a = size - 11 + i % 3
            b = i // 3
            set_fn(a, b, bit)                # 右上：列 size-11..size-9，行 0..5
            set_fn(b, a, bit)                # 左下：转置

    # 数据 + ECC + remainder bits，之字形放置
    stream = _encode_codewords(data, version)
    total_bits = len(stream) * 8 + _REMAINDER_BITS[version]

    def stream_bit(i):
        if i >= len(stream) * 8:
            return False
        return bool((stream[i >> 3] >> (7 - (i & 7))) & 1)

    idx = 0
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        upward = ((right + 1) & 2) == 0
        rng = range(size - 1, -1, -1) if upward else range(size)
        for vert in rng:
            for j in range(2):
                c = right - j
                if not fn[vert][c]:
                    m[vert][c] = stream_bit(idx) if idx < total_bits else False
                    idx += 1
        right -= 2

    # 掩码（仅数据区）
    masks = [
        lambda r, c: (r + c) % 2 == 0,
        lambda r, c: r % 2 == 0,
        lambda r, c: c % 3 == 0,
        lambda r, c: (r + c) % 3 == 0,
        lambda r, c: (r // 2 + c // 3) % 2 == 0,
        lambda r, c: (r * c) % 2 + (r * c) % 3 == 0,
        lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
        lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0,
    ]
    for r in range(size):
        for c in range(size):
            if not fn[r][c] and masks[mask_id](r, c):
                m[r][c] = not m[r][c]
    return m


def _penalty(m):
    size = len(m)
    p = 0
    for row in (m, zip(*m)):                              # N1
        for line in row:
            run, prev = 1, None
            for v in line:
                if v == prev:
                    run += 1
                else:
                    if prev is not None and run >= 5:
                        p += 3 + run - 5
                    run, prev = 1, v
            if prev is not None and run >= 5:
                p += 3 + run - 5
    for r in range(size - 1):                             # N2
        for c in range(size - 1):
            if m[r][c] == m[r][c + 1] == m[r + 1][c] == m[r + 1][c + 1]:
                p += 3
    pat = [True, False, True, True, True, False, True]
    for r in range(size):                                 # N3
        for c in range(size - 10):
            if m[r][c:c + 7] == pat and all(not x for x in m[r][max(0, c - 4):c]) \
                    and all(not x for x in m[r][c + 7:c + 11]):
                p += 40
            col = [m[i][c] for i in range(r, min(size, r + 11))]
            if len(col) == 11 and col[0:7] == pat and all(not x for x in col[7:]):
                p += 40
    dark = sum(v for row in m for v in row)               # N4
    total = size * size
    p += 10 * (abs(dark * 100 // total - 50) // 5)
    return p


def qr_matrix(text, ec_level_unused=None):
    """返回 (矩阵, 版本, mask)；矩阵元素为 bool，True=深色。"""
    data = text.encode("utf-8")
    if len(data) > MAX_BYTES:
        raise ValueError(f"内容过长：{len(data)} 字节 > {MAX_BYTES}")
    version = _pick_version(len(data))
    best = None
    for mask_id in range(8):
        m = _build_matrix(data, version, mask_id)
        score = _penalty(m)
        if best is None or score < best[0]:
            best = (score, m, mask_id)
    return best[1], version, best[2]


_DARK_FG, _LIGHT_FG = "\x1b[30m", "\x1b[97m"
_DARK_BG, _LIGHT_BG = "\x1b[40m", "\x1b[47m"
_RESET, _HALF = "\x1b[0m", "▀"


def render(text, quiet=4):
    """终端渲染：每个字符单元上下各一个模块，显式黑白颜色。"""
    m, _, _ = qr_matrix(text)
    n = len(m)
    g = [[False] * (n + 2 * quiet) for _ in range(quiet)] + \
        [row[:] + [False] * 2 * quiet for row in m] + \
        [[False] * (n + 2 * quiet) for _ in range(quiet)]
    lines = []
    for r in range(0, len(g), 2):
        bot = g[r + 1] if r + 1 < len(g) else [False] * len(g[r])
        parts = []
        for c in range(len(g[r])):
            top, bottom = g[r][c], bot[c]
            fg = _DARK_FG if top else _LIGHT_FG
            bg = _DARK_BG if bottom else _LIGHT_BG
            parts.append(f"{fg}{bg}{_HALF}{_RESET}")
        lines.append("".join(parts))
    return "\n".join(lines)


def main(argv):
    if len(argv) >= 3 and argv[1] == "--json":
        m, version, mask = qr_matrix(argv[2])
        print(json.dumps({"size": len(m), "version": version, "mask": mask,
                          "matrix": [[int(v) for v in row] for row in m]}))
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        print(render(argv[1]))
    except ValueError as e:
        print(f"qrcode: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
