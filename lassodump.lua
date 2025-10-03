-- Lasso Spy v1.0
-- Paste into executor (Synapse/Script-Ware/etc).
-- Non-destructive: forwards every call to original method.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService") -- only used for pretty JSON if available

-- Adjust this path if folder name differs
local replicationRoot = ReplicatedStorage:FindFirstChild("_replicationFolder", true)
if not replicationRoot then
    warn("Replication root '_replicationFolder' not found in ReplicatedStorage.")
    return
end

local target = replicationRoot:FindFirstChild("Lasso", true)
if not target then
    warn("Target 'Lasso' not found under _replicationFolder.")
    return
end

-- global log store (accessible from other scripts in executor)
_G.__LASSO_SPY_LOGS = _G.__LASSO_SPY_LOGS or {}

local function prettyPrint(...)
    local ok, encoded = pcall(function()
        local t = {...}
        return HttpService:JSONEncode(t)
    end)
    if ok then
        return encoded
    else
        -- fallback
        local parts = {}
        for i=1,select("#", ...) do
            local v = select(i, ...)
            table.insert(parts, tostring(v))
        end
        return table.concat(parts, ", ")
    end
end

local function dumpInstance(inst, indent, maxDepth, visited)
    indent = indent or ""
    maxDepth = maxDepth or 3
    visited = visited or {}
    if visited[inst] or maxDepth < 0 then
        return indent .. tostring(inst) .. " (already/too deep)\n"
    end
    visited[inst] = true

    local out = {}
    table.insert(out, indent .. string.format("%s (%s)", inst.Name, inst.ClassName))
    -- print some useful properties for common classes
    if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") then
        table.insert(out, indent .. "  -> Remote (Event/Function)")
    elseif inst:IsA("ModuleScript") then
        table.insert(out, indent .. "  -> ModuleScript")
    end

    -- show custom properties if exist
    local propList = {"Name", "ClassName", "Archivable", "Parent"}
    for _, p in ipairs(propList) do
        local ok, val = pcall(function() return inst[p] end)
        if ok and val ~= nil then
            table.insert(out, indent .. string.format("  %s: %s", p, tostring(val)))
        end
    end

    -- children
    local children = inst:GetChildren()
    if #children > 0 then
        table.insert(out, indent .. "  Children:")
        for _, c in ipairs(children) do
            table.insert(out, dumpInstance(c, indent .. "    ", maxDepth - 1, visited))
        end
    end
    return table.concat(out, "\n")
end

-- print initial dump
print("=== LASSO SPY: DUMP ===")
print(dumpInstance(target, "", 4))
print("=== END DUMP ===")

-- Helper to push to global logs (keeps small bounded buffer)
local function push_log(item)
    local logs = _G.__LASSO_SPY_LOGS
    table.insert(logs, 1, item)
    if #logs > 500 then -- keep recent 500
        for i=501,#logs do logs[i] = nil end
    end
end

-- Utility: check whether an instance is under target
local function isUnderTarget(inst)
    if not inst or not inst:IsA("Instance") then return false end
    local cur = inst
    while cur do
        if cur == target then return true end
        cur = cur.Parent
    end
    return false
end

-- Hook __namecall to intercept RemoteEvent/RemoteFunction calls under target
local mt = getrawmetatable(game)
local oldNamecall = mt.__namecall
local newNamecall
local getNamecallMethod = getnamecallmethod or function() return "" end
local checkCall = checkcaller or function() return false end

-- helper to capture stack (caller) without flooding
local function getCallerStack()
    local stack = ""
    -- xpcall to avoid breaking if debug.traceback unavailable
    local ok, tb = pcall(function() return debug.traceback("", 2) end)
    if ok and tb then
        stack = tb
    end
    return stack
end

newNamecall = newcclosure(function(self, ...)
    local method = getNamecallMethod()
    local argCount = select("#", ...)
    local args = {}
    for i=1, argCount do args[i] = select(i, ...) end

    local handled = false
    local logEntry

    -- If the target (or a child) is the receiver, and method is one of interest
    if isUnderTarget(self) then
        if method == "FireServer" or method == "FireClient" or method == "FireAllClients" or
           method == "InvokeServer" or method == "InvokeClient" then

            -- collect log info
            logEntry = {
                time = os.time(),
                method = method,
                receiver = tostring(self:GetFullName()),
                receiverClass = self.ClassName,
                args = args,
                callerStack = getCallerStack(),
            }

            -- For invokes, call and capture return
            if method:match("^Invoke") then
                local success, ret1, ret2, ret3 = pcall(function()
                    return oldNamecall(self, ...)
                end)
                logEntry.invokeSuccess = success
                if success then
                    -- if returned multiple values, capture them in table
                    local retvals = {}
                    if ret1 ~= nil then retvals[1] = ret1 end
                    if ret2 ~= nil then retvals[2] = ret2 end
                    if ret3 ~= nil then retvals[3] = ret3 end
                    logEntry.returns = retvals
                else
                    logEntry.error = tostring(ret1)
                end

                -- push to logs and also print short summary
                push_log(logEntry)
                print(string.format("[LASSO-SPY] %s -> %s args=%d invokeSucc=%s returns=%s",
                    logEntry.receiver, logEntry.method, #args,
                    tostring(logEntry.invokeSuccess),
                    prettyPrint(unpack(logEntry.returns or {}))
                ))

                -- return the actual result or rethrow if failed
                if logEntry.invokeSuccess then
                    return unpack(logEntry.returns or {})
                else
                    -- re-throw original error to preserve behavior
                    error(logEntry.error)
                end
            else
                -- Fire* : just forward and log
                local ok, err = pcall(function()
                    oldNamecall(self, ...)
                end)
                logEntry.fireSuccess = ok
                if not ok then logEntry.error = tostring(err) end
                push_log(logEntry)
                print(string.format("[LASSO-SPY] %s -> %s args=%d success=%s",
                    logEntry.receiver, logEntry.method, #args, tostring(ok)))
                return nil
            end
        end
    end

    -- default fallback - not related to Lasso: forward
    return oldNamecall(self, ...)
end)

-- set the new __namecall
setreadonly(mt, false)
mt.__namecall = newNamecall
setreadonly(mt, true)

print("[LASSO-SPY] Hooked __namecall. Logging remote calls for instances under:", target:GetFullName())

-- Auto-watch future children added under target
local function onDescendantAdded(desc)
    if desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") then
        print("[LASSO-SPY] New remote detected:", desc:GetFullName(), "(" .. desc.ClassName .. ")")
    end
end
target.DescendantAdded:Connect(onDescendantAdded)

-- Expose helper functions for use in executor console
_G.LassoSpyDump = function(depth)
    depth = depth or 4
    local txt = dumpInstance(target, "", depth)
    print(txt)
    return txt
end

_G.LassoSpyGetLogs = function(max)
    max = max or 50
    local out = {}
    for i=1, math.min(max, #_G.__LASSO_SPY_LOGS) do
        out[i] = _G.__LASSO_SPY_LOGS[i]
    end
    return out
end

print("[LASSO-SPY] Ready. Use LassoSpyDump(), LassoSpyGetLogs() to inspect.")
