--[[
    AIEnergy_ipc.lua - 跨平台 IPC 通信模块（文件版）

    与 vendored 的 bzx_ipc.lua 协议同源，但管道名改为 aienergy_rime，
    避免与原版 bzx 并存时冲突。通信仍走临时文件：
    - 请求文件 (aienergy_rime_req.txt): Lua 写入请求
    - 响应文件 (aienergy_rime_resp.txt): Python 服务写入响应，Lua 读取
--]]

local IPCManager = {}
IPCManager.__index = IPCManager

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

local function get_temp_dir()
    if is_windows() then
        return os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    else
        return "/tmp"
    end
end

function IPCManager.new(name)
    local self = setmetatable({}, IPCManager)
    self.name = name or "aienergy_rime"
    self.is_win = is_windows()

    local temp_dir = get_temp_dir()
    local sep = self.is_win and "\\" or "/"

    self.req_file = temp_dir .. sep .. self.name .. "_req.txt"
    self.resp_file = temp_dir .. sep .. self.name .. "_resp.txt"

    return self
end

-- 检测服务是否运行（检查响应文件是否存在）
function IPCManager:exists()
    local f = io.open(self.resp_file, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- 发送请求（写入请求文件）
function IPCManager:send(text)
    local f = io.open(self.req_file, "w")
    if not f then
        return false
    end

    local ok = pcall(function()
        f:write(text .. "\n")
        f:flush()
        f:close()
    end)

    if not ok then
        pcall(function() f:close() end)
        return false
    end

    return true
end

-- 读取响应（从响应文件读取）
function IPCManager:read()
    local f = io.open(self.resp_file, "r")
    if not f then
        return nil
    end

    local content = nil
    local ok = pcall(function()
        content = f:read("*a")
        f:close()
    end)

    if not ok then
        pcall(function() f:close() end)
        return nil
    end

    if content then
        content = content:gsub("^%s*(.-)%s*$", "%1")
    end

    if content and content ~= "" then
        return content
    end

    return nil
end

-- 解析消息类型
function IPCManager:parse_type(text)
    if not text then return nil end
    local msg_type = text:match('"type"%s*:%s*"([^"]*)"')
    return msg_type
end

-- 从响应 JSON 中提取 result 字段
function IPCManager:parse_result(text)
    if not text then return nil end
    local result = text:match('"result"%s*:%s*"([^"]*)"')
    if result then
        result = result:gsub("\\n", "\n"):gsub('\\"', '"')
        return result
    end
    return nil
end

-- 从响应 JSON 中提取 reqid 字段
function IPCManager:parse_reqid(text)
    if not text then return nil end
    return text:match('"reqid"%s*:%s*"([^"]*)"')
end

function IPCManager:close()
end

return IPCManager
