--[[
    correction.lua — 同步拼音纠错候选注入（规则 + 查表层）

    职责：在翻译阶段读取「错音 -> 正词」词典（correction_dict.txt），
    若当前组词拼音恰好是某条错音，则按用户设定的位置注入一条
    带「纠错」注释的候选。用户点选即填入，零延迟、原生态。

    注入位置（读 ~/Library/Rime/correction_position.txt）：
      · top         置顶（首位）
      · afterFirst 第一条自然候选之后（默认）
      · end         末尾

    设计要点：
      · 纯查表，不调用任何外部进程 / 模型 —— 与百度/搜狗同源机制，
        同步、零延迟、打字时确实生效。
      · 词典由离线生成器（tools/gen_correction_dict.py）从 rime-ice 词库
        施加「键盘邻键错打」+「系统性音近」噪声生成。
      · 仅当纠正词与自然候选不重复时才注入，避免冗余。
      · 词典只在首次使用时惰性加载并缓存，不阻塞按键。
--]]

local M = {}

local RIME_DIR = (os.getenv("HOME") or "") .. "/Library/Rime"
local DICT_PATH = RIME_DIR .. "/correction_dict.txt"            -- 键盘相邻错打层（基础档、标准档共用）
local PHONETIC_PATH = RIME_DIR .. "/correction_dict_phonetic.txt" -- 音近混淆层（仅标准档加载）
local STRENGTH_PATH = RIME_DIR .. "/correction_strength.txt"     -- 内容：basic / standard
local POSITION_PATH = RIME_DIR .. "/correction_position.txt"     -- 内容：top / afterFirst / end

local dict = nil
local dict_loaded = false

-- 读取纠错强度：basic（仅键盘相邻）/ standard（相邻 + 音近）。默认 standard。
local function read_strength()
  local f = io.open(STRENGTH_PATH, "r")
  if not f then return "standard" end
  local s = f:read("*l"):gsub("%s+$", ""):lower()
  f:close()
  if s == "basic" then return "basic" end
  return "standard"
end

-- 读取注入位置：top / afterFirst / end。默认 afterFirst（首条之后）。
local function read_position()
  local f = io.open(POSITION_PATH, "r")
  if not f then return "afterFirst" end
  local s = f:read("*l"):gsub("%s+$", ""):lower()
  f:close()
  if s == "top" then return "top" end
  if s == "end" then return "end" end
  return "afterFirst"
end

local function load_one(path, into)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local tab = line:find("\t")
    if tab then
      local typo = line:sub(1, tab - 1)
      local text = line:sub(tab + 1):gsub("%s+$", "")
      if #text > 0 then into[typo] = text end
    end
  end
  f:close()
end

local function load_dict()
  if dict_loaded then return end
  dict_loaded = true
  dict = {}
  -- 键盘相邻层始终加载（基础档、标准档都依赖它）
  load_one(DICT_PATH, dict)
  -- 标准档额外加载音近混淆层并合并
  if read_strength() == "standard" then
    load_one(PHONETIC_PATH, dict)
  end
end

function M.init(env)
  load_dict()
end

function M.func(input, env)
  local ctx = env.engine.context
  local cur = ctx.input or ""
  local correction = nil
  if #cur > 0 and dict then
    correction = dict[cur]
  end

  -- 收集本轮候选，便于按位置注入与去重判断
  local cands = {}
  for cand in input:iter() do
    cands[#cands + 1] = cand
  end

  -- 原输入查不出任何自然候选时（纯错音），直接给出纠正词（置顶）
  if #cands == 0 then
    if correction then
      yield(Candidate("correction", 0, #cur, correction, "纠错"))
    end
    return
  end

  -- 去重：纠正词已出现在自然候选中则不重复注入
  local dup = false
  if correction then
    for _, c in ipairs(cands) do
      if c.text == correction then dup = true; break end
    end
  end

  -- 无需注入时原样透传
  if not (correction and not dup) then
    for _, cand in ipairs(cands) do yield(cand) end
    return
  end

  local corr = Candidate("correction", 0, #cur, correction, "纠错")
  local pos = read_position()

  if pos == "top" then
    -- 置顶
    yield(corr)
    for _, cand in ipairs(cands) do yield(cand) end
  elseif pos == "end" then
    -- 末尾
    for _, cand in ipairs(cands) do yield(cand) end
    yield(corr)
  else
    -- afterFirst：第一条自然候选之后
    for i, cand in ipairs(cands) do
      yield(cand)
      if i == 1 then yield(corr) end
    end
  end
end

function M.fini(env)
end

return M
