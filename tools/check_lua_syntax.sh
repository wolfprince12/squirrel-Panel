#!/bin/bash
# 校验 Resources 下所有 .lua 不含 Lua 5.2+ 语法（鼠须管基于 LuaJIT，仅支持 5.1）。
# 违反则中断构建——Lua 5.2+ 语法会让 lua_filter / lua_translator 初始化失败，
# 导致整个 schema 引擎编译失败、中文无法输入（极具迷惑性，仅在重新部署时暴露）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUND=0
# 仅匹配高置信的 Lua 5.2+ 专属特征，避免误报注释 / 字符串里的 //：
#   1_000_000        数字下划线分隔符（5.2+）
#   goto             关键字（5.2+）
#   ::label::         标签语句（5.2+）
#   <C                C 函数边界写法（5.2+ 改动）
#   utf8.             utf8 标准库（5.3+）
PATTERN='1_000_000|2_000_000|goto[[:space:]]|::[A-Za-z]|<C[ ]|utf8\.'
while IFS= read -r -d '' f; do
  if grep -nE "$PATTERN" "$f"; then
    echo "Lua 5.2+ 语法出现在 $f（鼠须管仅支持 Lua 5.1，会导致 schema 编译失败、中文报废）"
    FOUND=1
  fi
done < <(find "$ROOT/Resources" -name '*.lua' -print0)
if [ "$FOUND" -ne 0 ]; then exit 1; fi
echo "Lua 语法校验通过（仅 5.1 兼容）"
