-- safe-logger.lua  (replace parts of your test.lua with this)
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local repFolder = RS:WaitForChild("_replicationFolder")
local ok, Lasso = pcall(require, repFolder:WaitForChild("Lasso"))

-- CONFIG
local DEPTH_LIMIT = 3
local MAX_ITEMS_PER_TABLE = 25
local LOG_BUFFER_SIZE = 800    -- เก็บ N ล่าสุด
local SKIP_INSTANCE_DETAILS = true -- ถ้า true: แสดงแค่ summary ของ Instance
local BLACKLIST_INSTANCE_NAMES = { ["Character"] = true } -- ปรับตามต้องการ
local SILENT_ARG_INDEX = { [2] = true } -- index ที่คุณอยากข้าม (ตามโค้ดเดิม)

-- circular buffer
local logBuffer = {}
local logStart = 1
local logCount = 0
local function pushLogEntry(s)
    if logCount < LOG_BUFFER_SIZE then
        logBuffer[logCount+1] = s
        logCount = logCount + 1
    else
        logBuffer[logStart] = s
        logStart = logStart % LOG_BUFFER_SIZE + 1
    end
end

-- safe serializer (limited depth & items)
local function safeDump(val, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth > DEPTH_LIMIT then
        return "...(depth limit)"
    end

    local t = typeof(val)
    if t == "table" then
        if seen[val] then return "{<cycle>}" end
        seen[val] = true
        local out = {"{"}
        local added = 0
        for k,v in pairs(val) do
            added = added + 1
            if added > MAX_ITEMS_PER_TABLE then
                table.insert(out, " ... (truncated) }")
                break
            end
            table.insert(out, ("\n%s[%s] = %s"):format(string.rep("  ", depth+1), tostring(k), safeDump(v, depth+1, seen)))
        end
        table.insert(out, "\n" .. string.rep("  ", depth) .. "}")
        return table.concat(out)
    elseif t == "Instance" then
        -- summary only
        if SKIP_INSTANCE_DETAILS then
            -- try to detect Character-like instances to reduce noise
            local name = val.Name or ""
            local class = val.ClassName or "Instance"
            if val:FindFirstChild("Humanoid") or string.match(name, "Character") then
                return ("Instance<%s>(%s)"):format(class, tostring(name))
            else
                return ("Instance<%s>:%s"):format(class, val:GetFullName() or tostring(name))
            end
        else
            return "Instance<"..val.ClassName..">:"..(val:GetFullName() or tostring(val))
        end
    elseif t == "function" then
        return "function(" .. tostring(val) .. ")"
    else
        local ok, s = pcall(function() return tostring(val) end)
        s = ok and s or "<tostring failed>"
        if #s > 200 then s = s:sub(1,200) .. "...(truncated)" end
        return t .. "(" .. s .. ")"
    end
end

-- push and optionally print
local function logf(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        table.insert(parts, safeDump(v))
    end
    local line = table.concat(parts, "\t")
    pushLogEntry(line)
    -- you can still print a short summary to Output:
    print("[SpyShort] ".. (line:sub(1,200)))
end

-- UI: simple scrolling UI that shows buffer
local function createLogUI()
    local player = Players.LocalPlayer
    if not player then return end
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "SpyLogUI"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = player:WaitForChild("PlayerGui")

    local frame = Instance.new("Frame", screenGui)
    frame.AnchorPoint = Vector2.new(1,1)
    frame.Position = UDim2.new(1,1,1, -40) -- bottom-right corner
    frame.Size = UDim2.new(0.45, 0, 0.4, 0)
    frame.BackgroundTransparency = 0.25

    local scroll = Instance.new("ScrollingFrame", frame)
    scroll.Size = UDim2.new(1, -10, 1, -10)
    scroll.Position = UDim2.new(0, 5, 0, 5)
    scroll.CanvasSize = UDim2.new(0,0,0,0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.VerticalScrollBarInset = Enum.ScrollBarInset.Always

    local uiList = Instance.new("UIListLayout", scroll)
    uiList.SortOrder = Enum.SortOrder.LayoutOrder
    uiList.Padding = UDim.new(0, 4)

    -- periodic updater
    spawn(function()
        while true do
            -- build combined text lines from buffer
            local lines = {}
            for i = 0, logCount-1 do
                local idx = ((logStart - 1 + i) % LOG_BUFFER_SIZE) + 1
                lines[#lines+1] = logBuffer[idx]
            end
            -- clear existing children then add latest (keep <= 300 labels to avoid UI heavy)
            for _,c in ipairs(scroll:GetChildren()) do
                if c:IsA("TextLabel") then c:Destroy() end
            end
            local startIdx = math.max(1, #lines - 300 + 1)
            for i = startIdx, #lines do
                local lbl = Instance.new("TextLabel")
                lbl.BackgroundTransparency = 1
                lbl.Size = UDim2.new(1, 0, 0, 16)
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.Font = Enum.Font.Code
                lbl.TextScaled = false
                lbl.Text = lines[i] or ""
                lbl.TextColor3 = Color3.new(1,1,1)
                lbl.TextSize = 14
                lbl.Parent = scroll
            end
            wait(0.5) -- update frequency (tweak as needed)
        end
    end)
end

-- wrapper utility (non-invasive, pcall, filter args)
local function safeWrap(tbl, fnName)
    if type(tbl[fnName]) == "function" then
        local old = tbl[fnName]
        tbl[fnName] = function(...)
            local args = {...}
            -- build a filtered summary of args
            local argSummaries = {}
            for i,v in ipairs(args) do
                if not SILENT_ARG_INDEX[i] then
                    table.insert(argSummaries, ("arg[%d]=%s"):format(i, safeDump(v)))
                else
                    table.insert(argSummaries, ("arg[%d]=<skipped>"):format(i))
                end
            end
            logf(("[Spy] %s called: %s"):format(fnName, table.concat(argSummaries, ", ")))
            local ok, ret1, ret2 = pcall(old, ...)
            if not ok then
                logf(("[Spy] %s -> error: %s"):format(fnName, tostring(ret1)))
            end
            return ret1, ret2
        end
        logf(("[Spy] Wrapped %s"):format(fnName))
    else
        logf(("[Spy] %s not a function, type=%s"):format(fnName, typeof(tbl[fnName])))
    end
end

-- initialize UI and wrap
createLogUI()
if ok and type(Lasso)=="table" then
    safeWrap(Lasso, "_hit")
    safeWrap(Lasso, "doLasso")
else
    logf("[Spy] Could not require Lasso module.")
end
