--[[
    correction.lua — 同步拼音纠错候选注入 + 用户自学习（规则 + 查表层）

    职责：
      1) 在翻译阶段读取「错音 -> 正词」词典（correction_dict.txt），若当前组词
         拼音恰好是某条错音，则按用户设定的位置注入带「纠错」注释的候选。
         多条候选按词频权重降序排（一对多 + 词频权重排序，Phase2）。
      2) 用户自学习（Phase3）：当用户上屏了某条「纠错」候选时，记录
         「输入拼音 -> 上屏词」到 correction_user.txt（权重累加）。下次同错音
         优先出该词。纯本地、零延迟、越用越准。

    注入位置（读 ~/Library/Rime/correction_position.txt）：
      · top         置顶（首位）
      · afterFirst 第一条自然候选之后（默认）
      · end         末尾

    自学习开关（读 ~/Library/Rime/correction_selflearn.txt）：
      · on  启用（默认）；off 关闭记录（已学字典仍参与注入）。

    设计要点：
      · 纯查表 + commit 监听，不调用任何外部进程 / 模型 —— 同步、零延迟。
      · 词典由离线生成器（tools/gen_correction_dict.py）从 rime-ice 词库
        施加「键盘邻键错打」+「系统性音近」噪声生成（一对多，带权重）。
      · 自学习记录走 commit_notifier，完全不碰按键流，零风险。
      · 词典只在首次使用时惰性加载并缓存，不阻塞按键。
--]]

local M = {}

local RIME_DIR = (os.getenv("HOME") or "") .. "/Library/Rime"
local DICT_PATH = RIME_DIR .. "/correction_dict.txt"             -- 键盘相邻错打层（基础档、标准档共用）
local PHONETIC_PATH = RIME_DIR .. "/correction_dict_phonetic.txt" -- 音近混淆层（仅标准档加载）
local STRENGTH_PATH = RIME_DIR .. "/correction_strength.txt"     -- 内容：basic / standard
local POSITION_PATH = RIME_DIR .. "/correction_position.txt"     -- 内容：top / afterFirst / end
local SELFLEARN_PATH = RIME_DIR .. "/correction_selflearn.txt"   -- 内容：on / off
local USER_DICT_PATH = RIME_DIR .. "/correction_user.txt"        -- 自学习字典：错音\t正词\t权重（运行时生成）

local dict = nil
local dict_loaded = false
local user_dict = nil        -- typo -> { hanzi -> weight }
local user_dirty = 0         -- 待落盘计数
local last_flush = 0         -- 上次落盘时间（os.time）

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

-- 自学习是否启用：默认 on。
local function selflearn_enabled()
  local f = io.open(SELFLEARN_PATH, "r")
  if not f then return true end
  local s = f:read("*l"):gsub("%s+$", ""):lower()
  f:close()
  return s ~= "off"
end

-- 解析一对多词典行：错音\t词1\t权重1\t词2\t权重2... -> {hanzi=weight}
local function parse_multi(rest)
  local toks = {}
  for token in rest:gmatch("[^\t]+") do
    toks[#toks + 1] = token
  end
  local map = {}
  local i = 1
  while i + 1 <= #toks do
    local hanzi = toks[i]
    local w = tonumber(toks[i + 1]) or 0
    map[hanzi] = w
    i = i + 2
  end
  return map
end

local function load_one(path, into_map)
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local tab = line:find("\t")
    if tab then
      local typo = line:sub(1, tab - 1)
      local rest = line:sub(tab + 1):gsub("%s+$", "")
      if #rest > 0 then
        local map = parse_multi(rest)
        if next(map) then into_map[typo] = map end
      end
    end
  end
  f:close()
end

-- 加载生成词典（键盘层 + 标准档音近层），typo -> {hanzi=weight}
local function load_dict()
  if dict_loaded then return end
  dict_loaded = true
  dict = {}
  load_one(DICT_PATH, dict)
  if read_strength() == "standard" then
    load_one(PHONETIC_PATH, dict)
  end
end

-- 加载用户自学习字典，typo -> {hanzi=weight}
local function load_user_dict()
  if user_dict then return end
  user_dict = {}
  load_one(USER_DICT_PATH, user_dict)
end

-- 把用户字典落盘（整文件重写，规模小、可靠）
local function flush_user_dict()
  if user_dirty == 0 or not user_dict then return end
  local f = io.open(USER_DICT_PATH, "w")
  if not f then return end
  -- 按错音排序，稳定可读
  local typos = {}
  for k, _ in pairs(user_dict) do typos[#typos + 1] = k end
  table.sort(typos)
  for _, typo in ipairs(typos) do
    local map = user_dict[typo]
    local parts = { typo }
    -- 按权重降序写，保持与生成词典一致的顺序约定
    local items = {}
    for h, w in pairs(map) do items[#items + 1] = { h, w } end
    table.sort(items, function(a, b) return a[2] > b[2] end)
    for _, it in ipairs(items) do
      parts[#parts + 1] = it[1]
      parts[#parts + 1] = tostring(it[2])
    end
    f:write(table.concat(parts, "\t") .. "\n")
  end
  f:close()
  user_dirty = 0
  last_flush = os.time()
end

-- 记录一条学习：输入拼音 -> 上屏词（权重 +1）
local function learn(typo, hanzi)
  if not user_dict then load_user_dict() end
  local map = user_dict[typo]
  if not map then
    map = {}
    user_dict[typo] = map
  end
  map[hanzi] = (map[hanzi] or 0) + 1
  user_dirty = user_dirty + 1
  local now = os.time()
  -- 节流：累计 20 条或距上次落盘超 10 秒则落盘
  if user_dirty >= 20 or (now - last_flush) >= 10 then
    flush_user_dict()
  end
end

function M.init(env)
  load_dict()
  load_user_dict()
  -- 提交监听：用户上屏时判断是否采纳了某条纠错候选，是则记录。
  local ok, conn = pcall(function()
    return env.engine.context.commit_notifier:connect(function(ctx)
      if not selflearn_enabled() then return end
      local input = ctx.input or ""
      local commit = ctx.commit_text or ""
      if #input == 0 or #commit == 0 then return end
      -- 仅当该输入是已知错音、且上屏词是其纠错候选之一时才学（避免记录正常输入）
      local gen = dict and dict[input]
      local usr = user_dict and user_dict[input]
      local is_correction_candidate = false
      if gen and gen[commit] then is_correction_candidate = true end
      if usr and usr[commit] then is_correction_candidate = true end
      if is_correction_candidate then
        learn(input, commit)
      end
    end)
  end)
  if not ok then
    -- 老版本 Rime 无 commit_notifier 时静默降级（仅不记录，纠错仍可用）
    user_dict = user_dict or {}
  end
end

-- 收集某错音的「有序候选列表」，用户词优先（权重叠加后降序）
local function candidates_for(cur)
  local merged = {}  -- hanzi -> weight
  if dict and dict[cur] then
    for h, w in pairs(dict[cur]) do merged[h] = w end
  end
  if user_dict and user_dict[cur] then
    for h, w in pairs(user_dict[cur]) do
      -- 用户词加权到亿级：生成词典词频仅几十万量级，单次采纳即可让该词
      -- 稳定排到最前（用户明确选择，应当优先）；多条用户词按采纳次数排序。
      merged[h] = (merged[h] or 0) + w + 1_000_000_000
    end
  end
  local list = {}
  for h, w in pairs(merged) do list[#list + 1] = { h, w } end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local out = {}
  for _, it in ipairs(list) do out[#out + 1] = it[1] end
  return out
end

function M.func(input, env)
  local ctx = env.engine.context
  local cur = ctx.input or ""
  local corrections = (#cur > 0 and dict) and candidates_for(cur) or nil

  -- 收集本轮候选，便于按位置注入与去重判断
  local cands = {}
  for cand in input:iter() do
    cands[#cands + 1] = cand
  end

  -- 原输入查不出任何自然候选时（纯错音），直接给出纠正词列表（置顶）
  if #cands == 0 then
    if corrections then
      for _, text in ipairs(corrections) do
        yield(Candidate("correction", 0, #cur, text, "纠错"))
      end
    end
    return
  end

  -- 去重：纠正词已出现在自然候选中则不重复注入
  local function is_dup(text)
    for _, c in ipairs(cands) do
      if c.text == text then return true end
    end
    return false
  end
  local remaining = {}
  if corrections then
    for _, text in ipairs(corrections) do
      if not is_dup(text) then remaining[#remaining + 1] = text end
    end
  end

  -- 无需注入时原样透传
  if #remaining == 0 then
    for _, cand in ipairs(cands) do yield(cand) end
    return
  end

  local pos = read_position()

  if pos == "top" then
    for _, text in ipairs(remaining) do
      yield(Candidate("correction", 0, #cur, text, "纠错"))
    end
    for _, cand in ipairs(cands) do yield(cand) end
  elseif pos == "end" then
    for _, cand in ipairs(cands) do yield(cand) end
    for _, text in ipairs(remaining) do
      yield(Candidate("correction", 0, #cur, text, "纠错"))
    end
  else
    -- afterFirst：第一条自然候选之后依次插入多条纠正候选（仍按权重降序）
    for i, cand in ipairs(cands) do
      yield(cand)
      if i == 1 then
        for _, text in ipairs(remaining) do
          yield(Candidate("correction", 0, #cur, text, "纠错"))
        end
      end
    end
  end
end

function M.fini(env)
  -- 退出前确保未落盘的学习记录写盘
  pcall(flush_user_dict)
end

return M
