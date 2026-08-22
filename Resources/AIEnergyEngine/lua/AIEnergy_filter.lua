--[[
    AIEnergy_filter.lua - 自研前端（overlay，不修改 bzx_*.lua）

    读取 /tmp/aienergy_rime_resp.txt 的响应，按 reqid 与当前在途请求配对：
      · 匹配且 result 非空 → 将 AI 结果注入候选槽位 candidate_index
        （由控制面板配置，默认第 9）。
      · reqid 不匹配（已被新按键覆盖 / 飞行中取消）→ 丢弃，绝不注入过期结果。
    设计文档 D4：结果占据可配置候选槽位，永不占首候选 0。
--]]

local M = {}
local ipc_mod = require("AIEnergy_ipc")
local state_mod = require("AIEnergy_state")

function M.init(env)
  state_mod.reload_config()
end

function M.func(input, env)
  -- 每次注入前重新读取面板配置（candidate_index / 纠错开关等），
  -- 不依赖 Rime deploy 触发 init——用户改配置后下次输入即生效。
  state_mod.reload_config()
  -- 收集原始候选
  local candidates = {}
  for cand in input:iter() do
    table.insert(candidates, cand)
  end
  if #candidates == 0 then return end

  local seg_start = candidates[1].start
  local seg_end = candidates[1]._end
  local st = state_mod.get_state()
  local idx_target = st.candidate_index or 9

  -- 读取响应并按 reqid 配对
  local ipc = ipc_mod.new("aienergy_rime")
  local resp = ipc:read()
  local ai_text = nil
  if resp then
    local resp_reqid = ipc:parse_reqid(resp)
    local result = ipc:parse_result(resp)
    if resp_reqid and resp_reqid == st.pending_reqid and result and #result > 0 then
      ai_text = result
    end
  end

  -- 在目标槽位插入 AI 候选；候选数不足时追加到末尾
  local idx = 0
  local injected = false
  for _, cand in ipairs(candidates) do
    idx = idx + 1
    if idx == idx_target and ai_text and not injected then
      local ac = Candidate("ai", seg_start, seg_end, ai_text, "「AI」")
      ac.quality = 10000
      yield(ac)
      injected = true
    end
    yield(cand)
  end
  if not injected and ai_text and idx < idx_target then
    local ac = Candidate("ai", seg_start, seg_end, ai_text, "「AI」")
    ac.quality = 10000
    yield(ac)
  end
end

function M.fini(env)
end

return M
