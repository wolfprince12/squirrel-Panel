#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
紫毫纠错模型 v3 — 正向拼音词表生成器

架构变更（v2 → v3）
-------------------
v2 做法：离线枚举「所有可能的错打串 → 词」，预生成 39 万条 / 6.9MB 的反向表。
        缺陷：① 只覆盖「相邻键替换」一类错误；② 若再加漏字/多字/换位/四字词，
        条目会膨胀到 300 万+ / 50MB+，体积与内存都不可接受。

v3 做法：只生成 **正向** 表（正确拼音串 → 候选词），错误类型的枚举挪到运行时。
        lua 在收到一个「非法且不是任何正确串前缀」的输入时，才对它枚举
        编辑距离 1 的四类变体（替换 / 漏字 / 多字 / 换位）去查这张正向表。
        - 覆盖面：四类错误全覆盖，且替换不再限于相邻键（任意 a-z 都能纠）
        - 体积：约 2MB（v2 的 6.9MB）
        - 内存：5 万键的表，比 v2 的 39 万键小一个数量级
        - 性能：单次输入约 300 次哈希查表，LuaJIT 下微秒级

输入：~/Library/Rime/cn_dicts/*.dict.yaml（rime-ice 出厂词库）
输出：Resources/CorrectionEngine/data/correction_pinyin.txt
      格式：每行 `拼音串<TAB>权重<TAB>词1,词2,...`
            拼音串 = 去空格无声调的实际键入形式（如 woshi）
            权重   = 该串下最高词频（lua 侧用于挑选最可信的纠错目标）
            词列表 = 按权重降序，最多 MAX_PER_PINYIN 个

注意：本脚本只产出纯 ASCII 拼音串与中文词，不引入任何 Lua 5.2+ 相关内容。
"""

import os
import heapq

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
RIME_DIR = os.path.expanduser("~/Library/Rime")
CN_DICTS_DIR = os.path.join(RIME_DIR, "cn_dicts")

# rime-ice 各词库排序不一致（8105 降序、base 升序），故不依赖行顺序，
# 全量解析后按权重取 Top-N。
SKIP_FILES = {"tencent.dict.yaml", "41448.dict.yaml"}

MAX_WORDS = 50_000       # 保留权重最高的 N 个 (词, 拼音) 对
MAX_PER_PINYIN = 5       # 每个拼音串最多保留的候选词数
MAX_WORD_LEN = 4         # 取 ≤4 字的词（含四字成语）
MAX_TYPED_LEN = 16       # 拼音串过长跳过（四字词约 12-16 字母）
MIN_TYPED_LEN = 2        # 单字母拼音串（简拼）不进表，避免噪声

OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Resources", "CorrectionEngine", "data", "correction_pinyin.txt"
)


def is_cjk_word(w: str) -> bool:
    if not w:
        return False
    for ch in w:
        # 基本汉字区 + 扩展 A（跳过标点/ASCII/符号）
        if not (0x4E00 <= ord(ch) <= 0x9FFF or 0x3400 <= ord(ch) <= 0x4DBF):
            return False
    return True


def typed_form(pinyin: str) -> str:
    """拼音 -> 用户实际键入串：去空格、转小写、只保留 a-z。"""
    s = pinyin.replace(" ", "").lower()
    return "".join(ch for ch in s if "a" <= ch <= "z")


def parse_dict(path: str):
    """解析一个 rime dict，yield (word, typed, weight)。"""
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("---"):
                continue
            # 词条一定含制表符；YAML 头字段（name:/sort:/...）不含，用此区分。
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
            if not typed or not (MIN_TYPED_LEN <= len(typed) <= MAX_TYPED_LEN):
                continue
            if not is_cjk_word(word) or len(word) > MAX_WORD_LEN:
                continue
            yield word, typed, weight


def main():
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)

    # 全量解析，用最小堆保留权重最高的 MAX_WORDS 个 (词, 拼音) 对。
    heap = []  # min-heap of (weight, word, typed)
    scanned = 0
    for fname in sorted(os.listdir(CN_DICTS_DIR)):
        if fname in SKIP_FILES or not fname.endswith(".dict.yaml"):
            continue
        path = os.path.join(CN_DICTS_DIR, fname)
        for word, typed, weight in parse_dict(path):
            scanned += 1
            if len(heap) < MAX_WORDS:
                heapq.heappush(heap, (weight, word, typed))
            elif weight > heap[0][0]:
                heapq.heapreplace(heap, (weight, word, typed))

    print(f"[gen] 扫描合规词条: {scanned}")
    print(f"[gen] 保留 Top {MAX_WORDS}: {len(heap)}")

    # 聚合：拼音串 -> [(word, weight), ...]
    agg = {}
    for weight, word, typed in heap:
        agg.setdefault(typed, []).append((word, weight))

    out_lines = []
    for typed in sorted(agg.keys()):
        items = agg[typed]
        items.sort(key=lambda x: -x[1])
        top_weight = items[0][1]
        words = [w for w, _ in items[:MAX_PER_PINYIN]]
        out_lines.append(f"{typed}\t{top_weight}\t{','.join(words)}")

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(out_lines))
        if out_lines:
            f.write("\n")

    size = os.path.getsize(OUT_PATH)
    print(f"[gen] 不同拼音串条目数: {len(out_lines)}")
    print(f"[gen] 输出文件: {OUT_PATH} ({size/1024/1024:.2f} MB)")

    # 估算 lua 侧前缀集合规模（lua 启动时从本表构建，不额外落盘）
    prefixes = set()
    for typed in agg.keys():
        for i in range(1, len(typed)):
            prefixes.add(typed[:i])
    print(f"[gen] lua 将构建前缀集合规模: {len(prefixes)}（用于识别输入中间态，不落盘）")

    # 抽查：这些「正确串」必须在表内，否则运行时纠不出来
    must_have = ["woshi", "women", "nihao", "zhongguo", "moqimiaomiao",
                 "xiexie", "mingtian", "shenme", "zenmeyang"]
    have = {line.split("\t", 1)[0] for line in out_lines}
    for k in must_have:
        mark = "✓" if k in have else "✗(不在表内)"
        print(f"[gen] 抽查正向键 {k}: {mark}")

    # 抽查：这些「错打串」不应在表内（它们靠运行时枚举纠正）
    must_not = ["eoshi", "wshi", "wooshi", "wsohi"]
    for k in must_not:
        mark = "✓(不在表，符合预期)" if k not in have else "✗(意外在表内)"
        print(f"[gen] 抽查错打串 {k}: {mark}")


if __name__ == "__main__":
    main()
