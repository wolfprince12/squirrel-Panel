-- 紫毫纠错模型 v3 — 运行时四类错误纠正
-- lua_filter@*amethyst_corrector：读 env.engine.context.input 的整串拼音，
-- 对真正打错的串注入「纠错」候选。与机制 A（speller/algebra derive）互补。
--
-- v2 → v3 架构变更
-- ----------------
-- v2：离线预生成「所有错打串 → 词」的反向表（39 万条 / 6.9MB），运行时精确查表。
--     只覆盖「相邻键替换」一类错误；要加漏字/多字/换位/四字词，表会膨胀到 50MB+。
-- v3：只加载 **正向** 表（正确拼音串 → 词，4 万条 / 1MB），把错误类型的枚举挪到运行时。
--     命中一个「非法且非中间态」的输入时，才枚举它的编辑距离 1 变体去查正向表：
--       · 换位  wsohi -> woshi   （打字快，相邻两键顺序颠倒）
--       · 多字  wooshi -> woshi  （手指弹跳，多打一个）
--       · 替换  eoshi  -> woshi  （打偏，相邻键优先、任意键兜底）
--       · 漏字  wshi   -> woshi  （漏一个键）
--
-- 何时才启动枚举（性能与噪声的关键）
-- ----------------------------------
--   1) 输入在正向表里     -> 是常见词的正确拼音，正常输入，透传
--   2) 输入是某个键的前缀 -> 用户还在打（如打 woshi 途中的 wos / wosh），透传
--   3) 以上都不是         -> 真打错了，才枚举
-- 因此正常打字的每一次按键都零额外开销；只有真打错的那一下才做约 300~450 次
-- 哈希查表（LuaJIT 下微秒级，且此时用户本就在停顿）。
--
-- 仅用 Lua 5.1 语法（鼠须管基于 LuaJIT，禁用 5.2+ 特性）
-- -----------------------------------------------------
--   拼音为纯 ASCII，长度一律 #s 取字节数，绝不碰 utf8 模块（5.3 才有）；
--   不用 goto / 整数除法 // / 数字下划线 / load（5.1 是 loadstring）；
--   文件与枚举全程 pcall 包裹，任一环节失败即静默降级，绝不拖垮候选框。

local M = {}

-- 数据文件（由面板 deployCorrectionAssets 复制到 ~/Library/Rime/）
local DICT_FILE = "/Library/Rime/correction_pinyin.txt"
local POS_FILE = "/Library/Rime/correction_position.txt"

-- 正向表：pinyin -> { w = 最高词频, s = "词1,词2,..." }
local DICT = {}
-- 前缀集合：正向表所有键的所有真前缀 -> true（识别输入中间态，启动时构建，不落盘）
local PREFIX = {}
local LOADED = false

-- 候选注入位置：top（首位）/ afterFirst（次位，默认）
local POSITION = "afterFirst"

local MIN_LEN = 4    -- 输入长度门槛：太短信息量不足，误纠风险高
local MAX_LEN = 16   -- 过长不枚举（性能保护，四字词约 12~16 字母）
-- 最多注入几条纠错候选。默认 1：只给「最接近」的那一条（按 词频×系数 排序第一），
-- 避免多条纠错候选把用户原本想打的词挤到后面、增加翻页/选词难度。
-- 预留 correction_count.txt（由面板「纠错候选数量」控制写入，1~3），缺省=1。
local MAX_OUT = 1

local LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- 单音节集合：用于抑制「单字纠错」噪声。
-- 4+ 字母的错打几乎总是多音节词（如 woshi），把整串删/插一个字母得到的单音节
-- （如 wshi 删 w → shi）是编辑距离枚举的假阳性，且单音节词频（是/我/的…）高出
-- 多音节几个数量级，纯系数调参无法压制。故直接跳过单音节候选。
local SYL = {}
do
  local s = "a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu cha chai chan chang chao che chen cheng chi chong chou chu chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de deng di dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu long lou lu luan lue lun luo lv ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun r ran rang rao re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo"
  for w in s:gmatch("%S+") do SYL[w] = true end
end

-- QWERTY 8 邻域：相邻键错打远比隔键错打常见，故给更高权重系数。
local NEIGHBORS = {
  q = "was",      w = "qeasd",    e = "wrsdf",    r = "etdfg",
  t = "ryfgh",    y = "tughj",    u = "yihjk",    i = "uojkl",
  o = "ipkl",     p = "ol",
  a = "qwszx",    s = "qweadzxc", d = "wersfxcv", f = "ertdgcvb",
  g = "rtyfhvbn", h = "tyugjbnm", j = "yuihknm",  k = "uiojlm",
  l = "iopk",
  z = "asx",      x = "asdzc",    c = "sdfxv",    v = "dfgcb",
  b = "fghvn",    n = "ghjbm",    m = "hjkn",
}

-- 各错误类型的可信度系数（乘到词频上参与排序）。
local CO_SWAP = 1.0    -- 换位
local CO_NEAR = 1.0    -- 相邻键替换（仅相邻键，v3 已弃用任意键替换）
local CO_DEL = 0.9     -- 多字（删掉一个）
local CO_INS = 0.85    -- 漏字（插入一个）

-- 兜底：正向表加载失败时，仍保证核心样例可用。
local FALLBACK = {
  eoshi = "我是",
}

-- 加载正向表（每行：拼音串<TAB>权重<TAB>词1,词2,...），同时构建前缀集合。
local function loadDict()
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. DICT_FILE, "r")
  if not f then return end
  local data = f:read("*a")
  f:close()
  if not data or #data == 0 then return end
  local cnt = 0
  -- 末尾补换行确保最后一行被捕获；gmatch 对空匹配会自动前进，不会死循环。
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    local py, w, words = line:match("^(%S+)\t(%d+)\t(.+)$")
    if py and w and words then
      DICT[py] = { w = tonumber(w) or 0, s = words }
      cnt = cnt + 1
      for i = 1, #py - 1 do
        PREFIX[py:sub(1, i)] = true
      end
    end
  end
  if cnt > 0 then LOADED = true end
end

local function loadPosition()
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. POS_FILE, "r")
  if not f then return end
  local line = f:read("*l")
  f:close()
  if not line then return end
  local v = line:match("^%s*(%S+)")
  if v == "top" or v == "afterFirst" then
    POSITION = v
  end
end

-- 纠错候选数量：读 correction_count.txt（由面板「纠错候选数量」控制写入）。
-- 仅 1~3 有效，缺省/非法一律回退到 1（只给最接近的那一条）。
local function loadCount()
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. "/Library/Rime/correction_count.txt", "r")
  if not f then return end
  local line = f:read("*l")
  f:close()
  if not line then return end
  local v = tonumber(line:match("^%s*(%d+)"))
  if v and v >= 1 and v <= 3 then
    MAX_OUT = v
  end
end

function M.init(env)
  pcall(loadPosition)
  pcall(loadCount)
  pcall(loadDict)
end

-- 枚举 code 的编辑距离 1 变体，返回命中正向表的结果（按可信度降序）。
local function collect(code)
  local n = #code
  local best = {}   -- pinyin -> score

  local function try(v, coef)
    if v == code then return end
    if SYL[v] then return end   -- 抑制单音节假阳性（是/我/的…）
    local e = DICT[v]
    if e then
      local s = e.w * coef
      if not best[v] or best[v] < s then
        best[v] = s
      end
    end
  end

  -- 1) 换位：相邻两字母顺序颠倒（wsohi -> woshi）
  for i = 1, n - 1 do
    try(code:sub(1, i - 1) .. code:sub(i + 1, i + 1)
        .. code:sub(i, i) .. code:sub(i + 2), CO_SWAP)
  end

  -- 2) 多字：删掉一个字母（wooshi -> woshi）
  for i = 1, n do
    try(code:sub(1, i - 1) .. code:sub(i + 1), CO_DEL)
  end

  -- 3) 替换：仅相邻键（eoshi -> woshi）。v3 弃用任意键替换（远键误纠率过高，
  --    且单音节抑制已无法覆盖其产生的 模式/漠视 类高频假阳性）。
  for i = 1, n do
    local ch = code:sub(i, i)
    local pre = code:sub(1, i - 1)
    local suf = code:sub(i + 1)
    local nb = NEIGHBORS[ch]
    if nb then
      for k = 1, #nb do
        local c = nb:sub(k, k)
        try(pre .. c .. suf, CO_NEAR)
      end
    end
  end

  -- 4) 漏字：插入一个字母（wshi -> woshi）
  for i = 0, n do
    local pre = code:sub(1, i)
    local suf = code:sub(i + 1)
    for k = 1, 26 do
      try(pre .. LETTERS:sub(k, k) .. suf, CO_INS)
    end
  end

  local arr = {}
  for v, s in pairs(best) do
    table.insert(arr, { v = v, s = s })
  end
  table.sort(arr, function(a, b)
    if a.s == b.s then return a.v < b.v end
    return a.s > b.s
  end)
  return arr
end

function M.func(input, env)
  local ctx = env.engine.context
  local code = ctx.input or ""

  -- 收集上游候选（先全部取出，便于按位置插入纠错候选）
  local upstream = {}
  for cand in input:iter() do
    table.insert(upstream, cand)
  end

  local corrections = {}
  local seen = {}
  local function add(text)
    if text and text ~= "" and not seen[text] and #corrections < MAX_OUT then
      seen[text] = true
      table.insert(corrections, text)
    end
  end

  local n = #code
  -- 只处理纯小写字母串（带分隔符 ' / 数字 / 大写的一律不碰）
  if code:match("^[a-z]+$") and n >= MIN_LEN and n <= MAX_LEN then
    if LOADED then
      -- 门槛：既不是正确拼音（DICT），也不是输入中间态（PREFIX），才判定为真打错。
      if not DICT[code] and not PREFIX[code] then
        local ok, arr = pcall(collect, code)
        if ok and arr then
          for i = 1, #arr do
            if #corrections >= MAX_OUT then break end
            local e = DICT[arr[i].v]
            if e then
              for w in e.s:gmatch("([^,]+)") do
                add(w)
              end
            end
          end
        end
      end
    else
      -- 正向表不可用时的兜底路径
      local fb = FALLBACK[code]
      if fb then
        for w in fb:gmatch("([^,]+)") do
          add(w)
        end
      end
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
  else -- afterFirst（次位，默认）
    if #upstream > 0 then yield(upstream[1]) end
    for i = 1, #corrections do emit(i) end
    for k = 2, #upstream do yield(upstream[k]) end
  end
end

return M
