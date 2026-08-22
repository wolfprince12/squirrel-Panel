--[[
    AIEnergy_processor.lua - 自研前端（overlay，不修改 bzx_*.lua）

    按键交互（设计文档 D3，具体键位全部由控制面板配置，见 aienergy_config.lua）：
      · 纠错 = 停顿触发：选中候选变化时发送 correct 请求到 /tmp IPC，
        服务侧防抖（450ms）后才推理；飞行中取消（旧请求自动被服务丢弃）。
        纠错默认开启、跟随 AI 增强总开关，无独立关闭。
      · 翻译 / 对话 = 面板配置的快捷键（默认 Control+t / Control+d，请求 type 为
        "translate" / "chat"，与服务端 PROMPTS 对齐），均不占用数字键。
    本 processor 只写请求、不拦截按键（始终返回 kNoop），
    结果注入由 AIEnergy_filter.lua 完成（候选槽位 candidate_index，由面板配置）。
--]]

local M = {}
local ipc_mod = require("AIEnergy_ipc")
local state_mod = require("AIEnergy_state")

-- 生成唯一请求 id（飞行中取消的配对键）
local function gen_reqid()
  return tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
end

-- 字符串转义，安全塞进 JSON 字符串
local function json_escape(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  return s
end

-- 发送一次请求到 /tmp/aienergy_rime_req.txt
local function send_request(type_, text)
  if not text or #text == 0 then return end
  local reqid = gen_reqid()
  state_mod.set_pending(reqid, text)
  local payload = string.format('{"reqid":"%s","type":"%s","text":"%s"}',
    reqid, type_, json_escape(text))
  local ipc = ipc_mod.new("aienergy_rime")
  ipc:send(payload)
end

-- 规范化组合键为 { key, mods }（大小写与修饰键顺序无关），便于与面板配置比对。
local MOD_MAP = {
  control = "control", ctrl = "control",
  alt = "alt", option = "alt",
  super = "super", cmd = "super", command = "super", meta = "super",
  shift = "shift",
  lock = "lock", caps = "lock",
}
local function canon(repr)
  if not repr or #repr == 0 then return nil end
  local parts = {}
  for p in repr:gmatch("[^%+]+") do parts[#parts + 1] = p end
  if #parts == 0 then return nil end
  local key = parts[#parts]:lower()
  local mods = {}
  for i = 1, #parts - 1 do
    local m = parts[i]:lower()
    m = MOD_MAP[m] or m
    mods[m] = true
  end
  return { key = key, mods = mods }
end

-- 两个组合键是否等价（修饰键集合与主键一致即视为相同）
local function same_hotkey(a, b)
  if not a or not b then return false end
  if a.key ~= b.key then return false end
  for k in pairs(a.mods) do if not b.mods[k] then return false end end
  for k in pairs(b.mods) do if not a.mods[k] then return false end end
  return true
end

function M.init(env)
  state_mod.reload_config()
end

function M.func(key, env)
  if key:release() then return 2 end

  local ctx = env.engine.context
  if not ctx:has_menu() then return 2 end
  local st = state_mod.get_state()

  -- 翻译 / 对话：由控制面板配置的快捷键触发（不再写死 t / d）
  local cur = canon(key:repr())
  if cur and st.translation_hotkey and same_hotkey(cur, canon(st.translation_hotkey)) then
    local cand = ctx.get_selected_candidate and ctx:get_selected_candidate()
    if cand then send_request("translate", cand.text) end
    return 2
  elseif cur and st.dialog_hotkey and same_hotkey(cur, canon(st.dialog_hotkey)) then
    local cand = ctx.get_selected_candidate and ctx:get_selected_candidate()
    if cand then send_request("chat", cand.text) end
    return 2
  end

  -- 停顿触发纠错：选中候选文本变化时发送 correct 请求（服务侧防抖 450ms 后才推理）。
  local cand = ctx.get_selected_candidate and ctx:get_selected_candidate()
  local text = (cand and cand.text) or (ctx.input or "")
  if text and text ~= st.pending_text then
    send_request("correct", text)
  end

  return 2  -- kNoop：绝不拦截按键
end

function M.fini(env)
end

return M
