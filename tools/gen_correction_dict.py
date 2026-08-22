#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
离线生成「错音 -> 正词」纠错词典（双层）。

两层噪声：
  1) 键盘相邻错打（KEYBOARD_ADJ）：单字符 1-edit 邻键替换。
     例：woshi(我是) 的 w 错打成邻键 e -> eoshi -> 我是。  → 基础档
  2) 系统性音近混淆（PHONETIC_ADJ）：n↔l / r↔l / h↔f 等方言/口音常见混淆，
     也是拼音输入法最高频的错因之一。                          → 标准档追加

输出两份 TSV（错音\\t正词）：
  - correction_dict.txt          键盘相邻层（基础档、标准档共用）
  - correction_dict_phonetic.txt 音近层（仅标准档加载，与键盘层合并）

两份词典按错音排序；同一错音取权重最高的正词。
这是同步纠错的「查表」层：运行时 lua_filter 按 ctx.input 查表注入，
零延迟、真生效，与百度/搜狗同源机制。3B 模型不在此参与。
"""

import os
import sys
import glob

# ---- QWERTY 邻键映射（仅字母，忽略数字行/符号）----
KEYBOARD_ADJ = {
    'q': ['w', 'a', 's'],
    'w': ['q', 'e', 'a', 's', 'd'],
    'e': ['w', 'r', 's', 'd', 'f'],
    'r': ['e', 't', 'd', 'f', 'g'],
    't': ['r', 'y', 'f', 'g', 'h'],
    'y': ['t', 'u', 'g', 'h', 'j'],
    'u': ['y', 'i', 'h', 'j', 'k'],
    'i': ['u', 'o', 'j', 'k', 'l'],
    'o': ['i', 'p', 'k', 'l'],
    'p': ['o', 'l'],
    'a': ['q', 'w', 's', 'z', 'x'],
    's': ['q', 'w', 'e', 'a', 'd', 'z', 'x', 'c'],
    'd': ['w', 'e', 'r', 's', 'f', 'x', 'c', 'v'],
    'f': ['e', 'r', 't', 'd', 'g', 'c', 'v', 'b'],
    'g': ['r', 't', 'y', 'f', 'h', 'v', 'b', 'n'],
    'h': ['t', 'y', 'u', 'g', 'j', 'b', 'n', 'm'],
    'j': ['y', 'u', 'i', 'h', 'k', 'n', 'm'],
    'k': ['u', 'i', 'o', 'j', 'l', 'm'],
    'l': ['i', 'o', 'p', 'k', 'm'],
    'z': ['a', 's', 'x'],
    'x': ['a', 's', 'd', 'z', 'c'],
    'c': ['s', 'd', 'f', 'x', 'v'],
    'v': ['d', 'f', 'g', 'c', 'b'],
    'b': ['f', 'g', 'h', 'v', 'n'],
    'n': ['g', 'h', 'j', 'b', 'm'],
    'm': ['h', 'j', 'k', 'n'],
}

# ---- 系统性音近混淆（方言/口音/拼音母语者最高频错因）----
# 单字母替换：n/l 不分、r/l 不分、h/f 不分。保守选取，避免过多误报。
PHONETIC_ADJ = {
    'n': ['l'],
    'l': ['n', 'r'],
    'r': ['l'],
    'h': ['f'],
    'f': ['h'],
}

# 权重阈值：只取常见词，控制词典规模
WEIGHT_MIN = 100
# 键盘层输出上限（按权重取 Top-N；25万条对 lua 运行时表压力可控）
MAX_ENTRIES_KEYBOARD = 250_000
# 音近层输出上限（标准档追加；15万条足够覆盖高频混淆）
MAX_ENTER_PHONETIC = 150_000


def spacefree(pinyin: str) -> str:
    return pinyin.replace(' ', '').replace("'", '').lower()


def parse_dict(path: str):
    """yield (spacefree_pinyin, hanzi, weight, n_syllables)"""
    try:
        f = open(path, encoding='utf-8')
    except OSError:
        return
    with f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            # 格式: 词语\t拼音(空格分隔)\t权重
            parts = line.split('\t')
            if len(parts) < 2:
                continue
            hanzi = parts[0].strip()
            pinyin = parts[1].strip()
            weight = 0
            if len(parts) >= 3:
                try:
                    weight = int(parts[2].strip())
                except ValueError:
                    weight = 0
            sf = spacefree(pinyin)
            if not sf or not sf.isalpha():
                continue
            n_syl = pinyin.count(' ') + 1
            if n_syl > 3:
                continue
            yield sf, hanzi, weight, n_syl


def gen_variants(sf: str, adj_map):
    """对字符串施加单字符替换（基于给定邻接/混淆表），yield 错音串（不含原串）"""
    for i, ch in enumerate(sf):
        for nb in adj_map.get(ch, ()):
            if nb == ch:
                continue
            yield sf[:i] + nb + sf[i + 1:]


def load_words():
    """从 rime-ice 词库构建 正词表：spacefree -> (hanzi, weight)"""
    rime_dir = os.path.expanduser('~/Library/Rime')
    bases = [
        os.path.join(rime_dir, 'cn_dicts', 'base.dict.yaml'),
        os.path.join(rime_dir, 'cn_dicts', '8105.dict.yaml'),
    ]
    words = {}
    for bp in bases:
        if not os.path.exists(bp):
            print(f'[warn] 缺失 {bp}', file=sys.stderr)
            continue
        for sf, hanzi, weight, n_syl in parse_dict(bp):
            if weight < WEIGHT_MIN:
                continue
            cur = words.get(sf)
            if cur is None or weight > cur[1]:
                words[sf] = (hanzi, weight)
    return words


def build_corrections(words, adj_map, cap):
    """基于某张混淆表生成 错音 -> (正词, weight)，按权重降序取 Top-N。"""
    corrections = {}
    for sf, (hanzi, weight) in words.items():
        for variant in gen_variants(sf, adj_map):
            if variant == sf:
                continue
            # 跳过错音恰好也是某正词的情况（避免给正确输入塞纠正）
            if variant in words:
                continue
            prev = corrections.get(variant)
            if prev is None or weight > prev[1]:
                corrections[variant] = (hanzi, weight)
    ranked = sorted(corrections.items(), key=lambda kv: -kv[1][1])
    if len(ranked) > cap:
        ranked = ranked[:cap]
    return sorted(ranked, key=lambda kv: kv[0])


def write_dict(items, out_name):
    out_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        '..', 'Resources', 'CorrectionEngine', out_name)
    out_path = os.path.abspath(out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as f:
        for typo, (hanzi, _w) in items:
            f.write(f'{typo}\t{hanzi}\n')
    print(f'[info] 输出 {out_name}: {len(items)} 条 -> {out_path}', file=sys.stderr)
    return out_path


def main():
    words = load_words()
    print(f'[info] 基底词数: {len(words)}', file=sys.stderr)

    kb = build_corrections(words, KEYBOARD_ADJ, MAX_ENTRIES_KEYBOARD)
    ph = build_corrections(words, PHONETIC_ADJ, MAX_ENTER_PHONETIC)

    write_dict(kb, 'correction_dict.txt')
    write_dict(ph, 'correction_dict_phonetic.txt')


if __name__ == '__main__':
    main()
