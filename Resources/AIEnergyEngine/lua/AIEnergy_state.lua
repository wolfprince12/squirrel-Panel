--[[
    AIEnergy_state.lua - 全局状态共享模块

    供 Processor 与 Filter 共享状态。Processor 负责更新，Filter 只读取。
    不通过文件通信，进程内 _G 共享即可。
--]]

if not _G.aienergy_state then
    _G.aienergy_state = {
        -- 当前已发送、等待响应的纠错请求 id（用于过期丢弃）
        pending_reqid = nil,
        -- 当前 composition 文本（与 pending_reqid 配对）
        pending_text = nil,
        -- 最近一次成功注入的结果（调试用）
        last_result = nil,
        -- 纠错功能是否开启（由控制面板配置，默认开）
        correction_on = true,
        -- 翻译快捷键（由控制面板配置，默认 Control+t）
        translation_hotkey = "control+t",
        -- 对话快捷键（由控制面板配置，默认 Control+d）
        dialog_hotkey = "control+d",
        -- 手动触发的类型（translate/chat）及其 reqid，用于让 Filter 注入到候选 0
        manual_reqid = nil,
        manual_type = nil,
        -- 加载提示文本
        loading_text = nil,
        -- 结果注入候选槽位（由控制面板配置，默认第 9，永不占首候选 0）
        candidate_index = 9,
    }
end

-- 从控制面板生成的 lua 配置读取交互参数（翻译/对话快捷键、候选槽位、纠错开关）。
-- 面板未生成或读取失败时，沿用上面 _G.aienergy_state 的默认值。
-- 强制每次重载都重新读取（Rime 部署后可能复用同一 lua VM，require 有缓存）。
local function load_ai_config()
  package.loaded["aienergy_config"] = nil
  local ok, cfg = pcall(require, "aienergy_config")
  if not (ok and type(cfg) == "table") then return end
  if type(cfg.translation_hotkey) == "string" then
    _G.aienergy_state.translation_hotkey = cfg.translation_hotkey
  end
  if type(cfg.dialog_hotkey) == "string" then
    _G.aienergy_state.dialog_hotkey = cfg.dialog_hotkey
  end
  if type(cfg.candidate_index) == "number" then
    _G.aienergy_state.candidate_index = cfg.candidate_index
  end
  if type(cfg.correction_on) == "boolean" then
    _G.aienergy_state.correction_on = cfg.correction_on
  end
end
load_ai_config()

local M = {}

-- 供 Processor / Filter 在每次 Rime 部署重载时重新读取面板配置
-- （lua VM 可能被复用，模块顶层不会重跑，必须在 init 中主动刷新）。
function M.reload_config()
  load_ai_config()
end

-- 记录一次待处理请求
function M.set_pending(reqid, text)
    _G.aienergy_state.pending_reqid = reqid
    _G.aienergy_state.pending_text = text
end

-- 记录一次手动触发请求
function M.set_manual(reqid, func_type, loading_text)
    _G.aienergy_state.manual_reqid = reqid
    _G.aienergy_state.manual_type = func_type
    _G.aienergy_state.loading_text = loading_text
end

-- 清除手动触发态
function M.clear_manual()
    _G.aienergy_state.manual_reqid = nil
    _G.aienergy_state.manual_type = nil
    _G.aienergy_state.loading_text = nil
end

function M.get_state()
    return _G.aienergy_state
end

return M
