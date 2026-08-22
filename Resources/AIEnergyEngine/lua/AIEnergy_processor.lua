--[[
    AIEnergy_processor.lua — AI 联想层触发器（Phase 2 MVP）

    职责：检测「短语边界」后，把上下文写入请求文件
    ~/Library/Rime/.aienergy_associate.json，由常驻的 SP-AIEnergyAgent 读取并拉起
    浮动联想条。

    设计要点：
      · 仅触发，不拦截：始终 return 2（kNoop），绝不吞掉按键。
      · 绝不注入候选（旧的 AIEnergy_filter 已彻底移除，候选注入这条路已砍）。
      · 自包含：不再 require AIEnergy_ipc / AIEnergy_state。
      · 触发时机：候选被提交（短语边界）→ 发 show；新一轮输入开始 → 发 hide。
        说明：Rime lua 没有可靠空闲计时器，真正的「停顿 N 毫秒」需计时器（见计划
        Phase 3），本 MVP 用 commit 边界近似：条会在「上一个短语提交、开始打下一个」
        时浮现，足够验证整条链路。

    注意：本文件由控制面板 / Agent 部署到 ~/Library/Rime/lua/，并在
    rime_ice.custom.yaml 的 engine/processors/@after 0 挂载。
--]]

local M = {}

-- 请求文件路径（与 SP-AIEnergyAgent 约定的同一文件）
local REQ_PATH = (os.getenv("HOME") or "") .. "/Library/Rime/.aienergy_associate.json"

-- 最小 JSON 字符串转义（上下文可能含引号/反斜杠/换行）
local function json_escape(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  return s
end

-- 写入请求文件（action: "show" 带上下文 / "hide"）
local function write_request(action, context)
  local payload
  if context and #context > 0 then
    payload = string.format('{"action":"%s","context":"%s","ts":%d}',
      action, json_escape(context), os.time())
  else
    payload = string.format('{"action":"%s","ts":%d}', action, os.time())
  end
  local ok, f = pcall(io.open, REQ_PATH, "w")
  if not ok or not f then return end
  f:write(payload)
  f:close()
end

-- 状态：上一次是否在组词（composing）中、最近一次候选文本
local was_composing = false
local last_phrase = ""

function M.init(env)
end

function M.func(key, env)
  if key:release() then return 2 end

  local ctx = env.engine.context
  local composing = ctx:has_menu()
  if composing then
    local cand = ctx.get_selected_candidate and ctx:get_selected_candidate()
    local text = (cand and cand.text) or (ctx.input or "")
    last_phrase = text
    -- 新的一轮输入刚开始：先隐藏上一条联想条
    if not was_composing then
      write_request("hide")
    end
  else
    -- 组词刚刚结束（候选被提交 = 短语边界）：请求续写联想
    if was_composing and last_phrase and #last_phrase > 0 then
      write_request("show", last_phrase)
    end
  end

  was_composing = composing
  return 2  -- kNoop：绝不拦截按键
end

function M.fini(env)
end

return M
