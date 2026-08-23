-- 雪狼智能纠错 v2 — 机制 B（键位错打型纠错）· 通用化稳定版
-- lua_filter@*snowwolf_corrector：读取 env.engine.context.input 的整串拼音，
-- 对「跨音节 / 含非法音节片段」的键位错打（如 eoshi -> 我是）注入纠错候选。
-- 与机制 A（speller/algebra derive）互补：A 处理「错成合法音节」的 typo（内核级零延迟），
-- B 处理 derive 永远不触发的跨音节错打。
--
-- 通用化（计划 #1）：纠错词表由离线生成器 tools/gen_correction_dict.py 从 rime-ice 词库
-- 全量产出「相邻键 1 次替换」映射（correction_map.txt），本脚本在 init 阶段一次性加载，
-- 运行时仅做 O(1) 精确查表 —— 任意单键邻位错打都能被纠正，零运行时翻译、零延迟。
--
-- 仅用 Lua 5.1 语法（鼠须管基于 LuaJIT，禁用 5.2+ 特性）：
--   拼音为纯 ASCII，长度一律用 #s 取字节数，绝不碰 utf8 模块（5.3 才有）。
--   所有对内核 translator 的探测均用 pcall 包裹，任一环节不可用即静默降级，
--   绝不抛错拖垮候选框。

local M = {}

-- 兜底映射：即使 correction_map.txt 缺失/加载失败，核心样例仍可用。
-- 值为逗号拼接的候选词串（与文件格式一致），func 中按需切分。
local CORRECTION_MAP = {
  eoshi = "我是,握手",
}

-- 纠错映射表数据文件路径（由面板 deployCorrectionAssets 复制到 ~/Library/Rime/）。
local MAP_FILE = "/Library/Rime/correction_map.txt"

-- 候选注入位置：top（置顶）/ afterFirst（首条之后=次位，默认），从 correction_position.txt 读取
local POSITION = "afterFirst"

-- 从 correction_map.txt 加载映射（每行：错打串<TAB>词1,词2,...）。
-- 纯 5.1 字符串处理：整文件读入后用 gmatch 逐行切分，零依赖、零风险。
local function loadCorrectionMap()
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. MAP_FILE, "r")
  if not f then return end
  local data = f:read("*a")
  f:close()
  if not data or #data == 0 then return end
  -- 末尾补换行，确保最后一行也能被捕获；gmatch 对空匹配会自动前进，不会死循环。
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    local typo, rest = line:match("^(%S+)\t(.*)$")
    if typo and rest and #rest > 0 then
      CORRECTION_MAP[typo] = rest
    end
  end
end

function M.init(env)
  -- 读取位置配置（文件不存在则用默认 afterFirst）
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. "/Library/Rime/correction_position.txt", "r")
  if f then
    local line = f:read("*l")
    f:close()
    if line then
      local v = line:match("^%s*(%S+)")
      if v == "top" or v == "afterFirst" then
        POSITION = v
      end
    end
  end
  -- 加载通用纠错词表（错打串 -> 候选词串）。失败静默降级，不影响中文输入。
  pcall(loadCorrectionMap)
end

function M.func(input, env)
  local ctx = env.engine.context
  local code = ctx.input

  -- 收集上游候选（先全部取出，便于按位置插入纠错候选）
  local upstream = {}
  for cand in input:iter() do
    table.insert(upstream, cand)
  end

  -- 纠错候选（去重）
  local corrections = {}
  local seen = {}
  local function add(text)
    if text and text ~= "" and not seen[text] then
      seen[text] = true
      table.insert(corrections, text)
    end
  end

  -- 映射表纠错（可靠路径）：精确查表，O(1)
  local mapped = CORRECTION_MAP[code]
  if mapped then
    for w in mapped:gmatch("([^,]+)") do
      add(w)
    end
  end

  -- 无纠错候选：直接透传上游
  if #corrections == 0 then
    for _, c in ipairs(upstream) do
      yield(c)
    end
    return
  end

  -- 按 POSITION 注入纠错候选（带「纠错」标记，quality 置顶）
  local function emit(idx)
    local c = Candidate("correction", 0, #code, corrections[idx], "「纠错」")
    c.quality = 100
    yield(c)
  end

  if POSITION == "top" then
    for i = 1, #corrections do emit(i) end
    for _, c in ipairs(upstream) do yield(c) end
  else -- afterFirst（首条之后=次位，默认）
    if #upstream > 0 then yield(upstream[1]) end
    for i = 1, #corrections do emit(i) end
    for k = 2, #upstream do yield(upstream[k]) end
  end
end

return M
