#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
雪狼智能纠错 v2 — 通用纠错词典生成器（机制 B 通用化）

设计目标（对应"任意相邻键错打自动纠错"）：
  把 rime-ice 词库里每个常见词的「用户实际键入的拼音串」(去空格、无声调，如 women)
  枚举其 **QWERTY 键盘相邻键 1 次替换** 的所有变体（如 eomen / womem / ...），
  把这些"错打串"映射到正确候选词。运行时 lua 只需对 context.input 做精确查表，
  即可对任意单键邻位错打注入纠错候选 —— 零运行时翻译、零延迟、纯 Lua 5.1。

输入：~/Library/Rime/cn_dicts/*.dict.yaml（rime-ice 出厂词库，按权重排序）
输出：Resources/CorrectionEngine/data/correction_map.txt
      格式：每行 `错打串<TAB>词1,词2,词3,...` （词按权重降序，最多 MAX_PER_TYPO 个）

为什么不用 Component.Translator 运行时翻译：
  Squirrel 基于 LuaJIT(5.1)，对内核 translator 的探测 API 不稳定（曾导致崩溃），
  且与"零延迟/零风险"铁律冲突。静态预生成词典可彻底规避运行时风险，
  覆盖量由本脚本控制，且查表是 O(1)。

注意：本脚本只解析、生成纯 ASCII 拼音串与中文词，不引入任何 5.2+ 语法或大模型。
"""

import os
import sys
import heapq

# ---------------------------------------------------------------------------
# QWERTY 键盘相邻键（8 邻域）
# ---------------------------------------------------------------------------
ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
POS = {}
for r, row in enumerate(ROWS):
    for c, ch in enumerate(row):
        POS[ch] = (r, c)

NEIGHBORS = {}
for ch, (r, c) in POS.items():
    nbs = []
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            if dr == 0 and dc == 0:
                continue
            nr, nc = r + dr, c + dc
            if 0 <= nr < len(ROWS) and 0 <= nc < len(ROWS[nr]):
                nbs.append(ROWS[nr][nc])
    NEIGHBORS[ch] = nbs

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
RIME_DIR = os.path.expanduser("~/Library/Rime")
CN_DICTS_DIR = os.path.join(RIME_DIR, "cn_dicts")

# 注意：rime-ice 各词库排序不一致（8105 降序、base 升序），
# 因此**不依赖行顺序**，全量解析后按权重堆取 Top-N 最常见词。
SKIP_FILES = {"tencent.dict.yaml", "41448.dict.yaml"}

MAX_WORDS = 15_000          # 全局只保留权重最高的 N 个 (词, 拼音) 对
MAX_PER_TYPO = 6            # 每个错打串最多保留的候选词数
MAX_WORD_LEN = 3            # 只取 ≤3 字的词/短语（单字+2字为主，3字常用短语）
MAX_TYPED_LEN = 12          # 拼音串过长跳过

OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Resources", "CorrectionEngine", "data", "correction_map.txt"
)


def is_cjk_word(w: str) -> bool:
    if not w:
        return False
    for ch in w:
        # 基本汉字区 + 扩展 A（够用，跳过标点/ASCII/符号）
        if not (0x4E00 <= ord(ch) <= 0x9FFF or 0x3400 <= ord(ch) <= 0x4DBF):
            return False
    return True


def typed_form(pinyin: str) -> str:
    """拼音 -> 用户实际键入串：去空格、转小写、只保留 a-z。"""
    s = pinyin.replace(" ", "").lower()
    return "".join(ch for ch in s if "a" <= ch <= "z")


def typo_variants(s: str):
    """对串 s 做 QWERTY 相邻键 1 次替换，返回所有 ≠ s 的变体。"""
    out = []
    for i, ch in enumerate(s):
        for nb in NEIGHBORS.get(ch, ()):
            variant = s[:i] + nb + s[i + 1:]
            if variant != s:
                out.append(variant)
    return out


def parse_dict(path: str):
    """解析一个 rime dict，yield (word, typed, weight)。"""
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("---"):
                continue
            # 跳过 YAML 头（name:/version:/sort:/import_tables: 等）
            if ":" in line and not line.startswith("\t") and " " not in line.split(":", 1)[0]:
                # 形如 "name: xxx" 或 "sort: by_weight"；但词条是 "词\t拼音\t权重"
                # 词条一定含制表符；头字段不含制表符。用制表符区分。
                if "\t" not in line:
                    continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            word, pinyin = parts[0], parts[1]
            weight = 0
            if len(parts) >= 3:
                try:
                    weight = int(parts[2])
                except ValueError:
                    weight = 0
            typed = typed_form(pinyin)
            if not typed or len(typed) > MAX_TYPED_LEN:
                continue
            if not is_cjk_word(word) or len(word) > MAX_WORD_LEN:
                continue
            yield word, typed, weight


def build_valid_set():
    """全量扫描词库，收集所有合法拼音串（去空格无声调）。

    用途：生成 typo 变体时，凡是「自身也是合法拼音」的串（如 ao / mi / an）
    一律剔除——这类串用户多半是正常输入，不应冒出「纠错」候选，否则几乎每次
    键入都会触发噪声。只保留真正非法的错打串（如 eoshi / wosji / womem）。
    """
    valid = set()
    for fname in sorted(os.listdir(CN_DICTS_DIR)):
        if fname in SKIP_FILES or not fname.endswith(".dict.yaml"):
            continue
        path = os.path.join(CN_DICTS_DIR, fname)
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#") or line.startswith("---"):
                    continue
                if ":" in line and "\t" not in line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                typed = typed_form(parts[1])
                if typed and len(typed) <= MAX_TYPED_LEN:
                    valid.add(typed)
    return valid


def main():
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)

    # 合法拼音串集合（用于过滤"自身就是合法拼音"的错打噪声）。
    valid_set = build_valid_set()
    print(f"[gen] 合法拼音串集合规模: {len(valid_set)}")

    # 全量解析，用最小堆保留权重最高的 MAX_WORDS 个词（与文件排序无关）。
    heap = []  # min-heap of (weight, word, typed)
    for fname in sorted(os.listdir(CN_DICTS_DIR)):
        if fname in SKIP_FILES or not fname.endswith(".dict.yaml"):
            continue
        path = os.path.join(CN_DICTS_DIR, fname)
        for word, typed, weight in parse_dict(path):
            if len(heap) < MAX_WORDS:
                heapq.heappush(heap, (weight, word, typed))
            elif weight > heap[0][0]:
                heapq.heapreplace(heap, (weight, word, typed))

    # 取出 Top-N（按权重降序）
    top = sorted(heap, key=lambda x: -x[0])
    print(f"[gen] 候选词总数(全量解析后保留 Top {MAX_WORDS}): {len(top)}")

    # typo -> list of (word, weight)
    raw = {}
    for weight, word, typed in top:
        for variant in typo_variants(typed):
            # 过滤：错打串自身若是合法拼音（如 ao/mi/an），多半是正常输入，不纠错。
            if variant in valid_set:
                continue
            raw.setdefault(variant, []).append((word, weight))

    # 每个 typo 保留权重最高的 MAX_PER_TYPO 个词
    out_lines = []
    for typo in sorted(raw.keys()):
        items = raw[typo]
        items.sort(key=lambda x: -x[1])
        words = [w for w, _ in items[:MAX_PER_TYPO]]
        out_lines.append(f"{typo}\t{','.join(words)}")

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(out_lines))
        if out_lines:
            f.write("\n")

    # 统计
    print(f"[gen] 生成错打串条目数: {len(out_lines)}")
    size = os.path.getsize(OUT_PATH)
    print(f"[gen] 输出文件: {OUT_PATH} ({size/1024:.1f} KB)")

    # 抽查关键样例（真实存在的相邻键错打）
    checks = ["eoshi", "eomen", "wosji", "woshj", "nihao", "women", "nihoa", "womem"]
    present = {}
    for line in out_lines:
        k = line.split("\t", 1)[0]
        if k in checks:
            present[k] = line.split("\t", 1)[1]
    for c in checks:
        if c in present:
            print(f"[gen] 抽查 {c} -> {present[c]}")
        else:
            print(f"[gen] 抽查 {c} -> (未生成/或本身是合法正确串)")


if __name__ == "__main__":
    main()
