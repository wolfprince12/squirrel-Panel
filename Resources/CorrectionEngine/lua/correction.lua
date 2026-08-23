--[[
    correction.lua — 轻量纠错候选位置重排器

    纠错候选由 speller/algebra 的 derive 规则生成（Rime 内核级、拼音编译期展开、
    零延迟），    本 filter **不查任何大词典、不做任何重量级计算**，只负责：
      1) 识别 derive 派生的纠错候选（用候选 comment 携带的拼写拼音与「错音→正音」映射对比）；
      2) 按 correction_position.txt 重排：top（置顶）/ afterFirst（首条后）/ end（末尾）；
      3) 用户自学习记录（commit_notifier，轻量，不影响候选生成）。

    与旧版「40 万行词典 lua 查表」的本质区别：旧版在 lua 里同步查 40 万行大表，
    每次按键触发 LuaJIT GC 扫描 → 打字卡顿。本版纠错已交回内核 derive，lua 只剩
    微秒级的 preedit 字符串对比，无大表、无 GC 压力。

    注入位置（读 ~/Library/Rime/correction_position.txt）：top / afterFirst / end。
    强度（读 ~/Library/Rime/correction_strength.txt）：basic / standard。
--]]

local RIME_DIR = (os.getenv("HOME") or "") .. "/Library/Rime"
local STRENGTH_PATH = RIME_DIR .. "/correction_strength.txt"
local POSITION_PATH = RIME_DIR .. "/correction_position.txt"
local SELFLEARN_PATH = RIME_DIR .. "/correction_selflearn.txt"

-- 错音 -> 正音（与 Swift correctionRules 严格一一对应）。
-- basic：键盘物理相邻错打（17 条）；standard：追加系统性音近（12 条）。
local BASIC_RULES = {
  eo = "wo",  mi = "ni",  gao = "hao", hao = "gao",
  ra = "ta",  ta = "ra",  sa = "da",   da = "sa",
  xi = "ci",  ci = "xi",  fa = "da",   da = "fa",
  li = "ni",  ni = "li",  ou = "uo",   ie = "ei",
  ei = "ie",
}
local STANDARD_RULES = {
  ji = "qi",   qi = "ji",   ju = "qu",     qu = "ju",
  wan = "wang", wang = "wan", min = "ming", ming = "min",
  zen = "zheng", zheng = "zen", fen = "feng", feng = "fen",
}

-- 配置缓存（M.init 读一次，热路径零 I/O）
local cfg_position = "afterFirst"
local cfg_selflearn = true
-- 有效规则表（按强度构建）
local rules = {}

local function read_line(path, default)
  local f = io.open(path, "r")
  if not f then return default end
  local s = f:read("*l") or ""
  f:close()
  return s:gsub("%s+$", ""):lower()
end

-- 去掉非小写字母（空格、声调、变音符等），得到纯拼音串
local function clean(s)
  return (s or ""):lower():gsub("[^a-z]", "")
end

-- 从候选 comment 提取拼写拼音。rime-ice 用 `comment_format` 把拼写包成 ［wo shi］
-- （全角括号，U+FF3B/FF3D），兼容 ASCII [ ]。spelling_hints:8 + always_show_comments:true
-- 保证每个拼音候选的 comment 都携带其真实拼写（派生后的正音，如把 eo 敲成 wo 后显示 ［wo shi］）。
-- 这正是官方 corrector.lua 判断纠错候选的同一信号，比 preedit 可靠（derive 候选的 preedit
-- 语义在不同版本不一致）。
local function spelling_of(cand)
  local c = cand.comment or ""
  local inner = c:match("^［(.-)］$") or c:match("^%[(.-)%]$")
  if not inner then return "" end
  return clean(inner)
end

-- 判断候选是否是「纠错候选」：其拼写 == 把输入串中某对错音替换成正音后的结果。
-- 配套 speller/algebra 的 derive：敲 eo 会被内核派生为 wo，候选拼写显示 ［wo shi］，
-- 而用户实际输入 raw="eoshi"；把 raw 中的 eo 替换为 wo 得 "woshi"，与拼写相等 → 命中纠错。
local function is_correction(cand, raw)
  local p = spelling_of(cand)
  if p == "" or p == raw then return false end
  for typo, correct in pairs(rules) do
    if raw:find(typo, 1, true) then
      local corrected = raw:gsub(typo, correct)
      if corrected == p then return true end
    end
  end
  return false
end

local M = {}

function M.init(env)
  local strength = read_line(STRENGTH_PATH, "standard")
  cfg_position = read_line(POSITION_PATH, "afterFirst")
  cfg_selflearn = read_line(SELFLEARN_PATH, "on") ~= "off"

  rules = {}
  for k, v in pairs(BASIC_RULES) do rules[k] = v end
  if strength ~= "basic" then
    for k, v in pairs(STANDARD_RULES) do rules[k] = v end
  end

  -- 自学习：用户上屏纠错候选时记录（轻量；derive 候选上屏后 Rime 内核也会自动学习，
  -- 这里仅做一份「错音→上屏词」的采纳日志，不参与候选生成、不影响性能）。
  if cfg_selflearn then
    pcall(function()
      env.engine.context.commit_notifier:connect(function(ctx)
        local raw = clean(ctx.input)
        local commit = ctx.commit_text or ""
        if raw == "" or commit == "" then return end
        -- 仅当输入串命中某对错音时才记录（避免记录正常输入）
        local is_typo = false
        for typo, _ in pairs(rules) do
          if raw:find(typo, 1, true) then is_typo = true break end
        end
        if not is_typo then return end
        local f = io.open(RIME_DIR .. "/correction_user.txt", "a")
        if f then
          f:write(raw .. "\t" .. commit .. "\n")
          f:close()
        end
      end)
    end)
  end
end

function M.func(input, env)
  local ctx = env.engine.context
  local raw = clean(ctx.input)

  local normal = {}
  local correction = {}
  for cand in input:iter() do
    if raw ~= "" and is_correction(cand, raw) then
      correction[#correction + 1] = cand
    else
      normal[#normal + 1] = cand
    end
  end

  -- 无纠错候选时原样透传
  if #correction == 0 then
    for _, c in ipairs(normal) do yield(c) end
    return
  end

  local pos = cfg_position
  if pos == "top" then
    for _, c in ipairs(correction) do yield(c) end
    for _, c in ipairs(normal) do yield(c) end
  elseif pos == "end" then
    for _, c in ipairs(normal) do yield(c) end
    for _, c in ipairs(correction) do yield(c) end
  else
    -- afterFirst：第一条自然候选之后依次插入纠错候选
    if #normal > 0 then
      yield(normal[1])
      for _, c in ipairs(correction) do yield(c) end
      for i = 2, #normal do yield(normal[i]) end
    else
      for _, c in ipairs(correction) do yield(c) end
    end
  end
end

function M.fini(env) end

return M
