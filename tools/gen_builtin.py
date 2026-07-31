#!/usr/bin/env python3
"""从 rime/squirrel 的 data/squirrel.yaml 生成 BuiltinDefaults.swift。

用法：
    python3 tools/gen_builtin.py /path/to/squirrel/data/squirrel.yaml

当上游更新了内置配色或默认样式时，重新跑一遍即可同步。
"""
import sys
import pathlib

DEFAULT_SRC = "../squirrel/data/squirrel.yaml"
OUT = pathlib.Path(__file__).parent.parent / "Sources/SquirrelPanel/Core/BuiltinDefaults.swift"

TEMPLATE = '''// 本文件由 tools/gen_builtin.py 从 rime/squirrel 的 data/squirrel.yaml 自动生成，请勿手动编辑。
// Auto-generated from rime/squirrel data/squirrel.yaml. Do not edit by hand.

import Foundation

enum BuiltinDefaults {{
  /// 官方 squirrel.yaml 原文，作为未安装鼠须管时的回退数据源
  static let squirrelYAML: String = #"""
{src}"""#
}}
'''


def main() -> int:
    src_path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC)
    if not src_path.exists():
        print(f"找不到源文件：{src_path}", file=sys.stderr)
        return 1
    src = src_path.read_text(encoding="utf-8")
    if '"""#' in src:
        print("源文件包含 Swift raw string 结束分隔符，需改用更长的 # 前缀", file=sys.stderr)
        return 1
    OUT.write_text(TEMPLATE.format(src=src), encoding="utf-8")
    print(f"已写入 {OUT}（{len(src)} 字符）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
