#!/bin/bash
# 校验 Resources 下所有 .lua 严格符合 Lua 5.1 语法（鼠须管基于 LuaJIT，仅支持 5.1）。
# 违反则中断构建——Lua 5.2+ 语法会让 lua_filter / lua_translator 初始化失败，
# 导致整个 schema 引擎编译失败、中文无法输入（极具迷惑性，仅在重新部署时暴露）。
#
# 校验方法（按优先级）：
#   1) luajit -bl 真 5.1 字节码编译（权威）：能抓绝大多数 5.2+ 语法错误（//、bit、goto、
#      数字下划线、utf8 库、load 等）。这是唯一可信的检查——fengari(5.3) 会漏报，不可用。
#   2) luajit 不可用时，退化为高置信 5.2+ 关键字 grep（仅兜底，可能漏）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 定位 luajit（brew 安装的 LuaJIT 2.x）
LUAJIT=""
if command -v luajit >/dev/null 2>&1; then
  LUAJIT="luajit"
elif [ -x /opt/homebrew/bin/luajit ]; then
  LUAJIT="/opt/homebrew/bin/luajit"
fi

# 兜底 grep 模式：仅匹配高置信的 Lua 5.2+ 专属特征，避免误报注释 / 字符串里的 //。
PATTERN='1_000_000|2_000_000|3_000_000|goto[[:space:]]|::[A-Za-z]|<C[ ]|utf8\.'

FAILED=0
while IFS= read -r -d '' f; do
  if [ -n "$LUAJIT" ]; then
    # 权威检查：字节码编译（不执行），语法错立即非零退出
    if ! "$LUAJIT" -bl "$f" /dev/null >/dev/null 2>&1; then
      echo "❌ Lua 5.1 语法错误（luajit 字节码编译失败）：$f"
      "$LUAJIT" -bl "$f" /dev/null || true
      FAILED=1
    fi
  else
    # 兜底：grep 关键字（可能漏报，仅当 luajit 缺失时启用）
    if grep -nE "$PATTERN" "$f"; then
      echo "⚠️ 疑似 Lua 5.2+ 语法出现在 $f（鼠须管仅支持 Lua 5.1，会导致 schema 编译失败、中文报废）"
      FAILED=1
    fi
  fi
done < <(find "$ROOT/Resources" -name '*.lua' -print0)

if [ "$FAILED" -ne 0 ]; then
  echo "Lua 语法校验未通过，构建已中断。"
  exit 1
fi

if [ -n "$LUAJIT" ]; then
  echo "✅ Lua 5.1 语法校验通过（luajit 字节码编译，权威）"
else
  echo "✅ Lua 语法校验通过（grep 兜底；建议安装 LuaJIT 以获得权威检查）"
fi
