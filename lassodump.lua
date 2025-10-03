-- Lasso Spy v1.1 (compat-safe)
-- Non-destructive Remote spy limited to ReplicatedStorage._replicationFolder.Lasso

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

-- ====== helpers / shims ======
local function exists(x) return type(x) ~= "nil" end
local has = {
    hookmetamethod = exists(hookmetamethod),
    getnamecallmethod = exists(getnamecallmethod),
    checkcaller = exists(checkcaller),
    newcclosure = exists(newcclosure),
    getrawmetatable = pcall(getrawmetatable, game),
    setreadonly = exists(setreadonly),
}
local getnc = has.getnamecallmethod and getnamecallmethod or function() return "" end
local isCaller = has.checkcaller and checkcaller or function() return false end

local function safeToString(v)
    local t = typeof(v)
    if t == "Instance" then
        return ("<%s:%s>"):format(v.ClassName, v:GetFullName())
    elseif t == "Vector3" or t == "CFrame" or t == "Vector2" or t == "UDim2" or t == "Color3" then
        return tostring(v)
    elseif t == "table" then
        local ok, enc = pcall(function() return HttpService:JSONEncode(v) end)
        return ok and enc or tostring(v)
    else
        return tostring(v)
    end
end

local function argsPreview(t)
    local out = {}
    for i = 1, select("#", t) do
        local v = select(i, t)
        out[#out+1] = safeToString(v)
    end
    return table.concat(out, ", ")
end

local function captureStack()
    local ok, tb = pcall(function() return debug.traceback("", 3) end)
    return ok and tb or ""
end

-- ====== find target ======
local replicationRoot = ReplicatedStorage:FindFirstChild("_replicationFolder", true)
if not replicationRoot then
    return warn("[LASSO-SPY] _replicationFolder not found under ReplicatedStorage")
end
local target = replicationRoot:FindFirstChild("Lasso", true)
if not target then
    return warn("[LASSO-SPY] Lasso not found under _replicationFolder")
end

local function isUnderTarget(inst)
    if not inst or typeof(inst) ~= "Instance" then return false end
    local cur = inst
    while cur do
        if cur == target then return true end
        cur = cur.Parent
    end
    return false
end

-- ====== dump (light) ======
local function lightDump(inst, depth, indent)
    depth = depth or 3
    indent = indent or ""
    if depth < 0 then return end
    print(("%s%s (%s)"):format(indent, inst.Name, inst.ClassName))
    for _, c in ipairs(inst:GetChildren()) do
        lightDump(c, depth - 1, indent .. "  ")
    end
end

print("=== LASSO-SPY: LIGHT DUMP ===")
lightDump(target, 4, "")
print("=== END DUMP ===")

_G.__LASSO_SPY_LOGS = _G.__LASSO_SPY_LOGS or {}
local function push_log(entry)
    table.insert(_G.__LASSO_SPY_LOGS, 1, entry)
    if #_G.__LASSO_SPY_LOGS > 500 then
        for i=501, #_G.__LASSO_SPY_LOGS do _G.__LASSO_SPY_LOGS[i] = nil end
    end
end

-- ====== hook strategy A: hookmetamethod (preferred) ======
local hooked = false
if has.hookmetamethod then
    local old
    old = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnc()
        -- ignore calls originating from us to reduce noise
        if isUnderTarget(self) and (method == "FireServer" or method == "FireClient" or method == "FireAllClients" or method == "InvokeServer" or method == "InvokeClient") then
            local packed = table.pack(...)
            local logEntry = {
                time = os.time(),
                method = method,
                receiver = self and self:GetFullName() or tostring(self),
                class = self and self.ClassName or "Unknown",
                argsPreview = argsPreview(packed),
                callerStack = captureStack(),
                originIsScript = isCaller(),
            }
            if method:sub(1,6) == "Invoke" then
                local ok, r1, r2, r3 = pcall(old, self, ...)
                logEntry.invokeSuccess = ok
                if ok then
                    logEntry.returnsPreview = argsPreview(table.pack(r1, r2, r3))
                else
                    logEntry.error = tostring(r1)
                end
                push_log(logEntry)
                print(("[LASSO-SPY] %s -> %s | args=[%s] | ok=%s | ret=[%s]"):format(logEntry.receiver, method, logEntry.argsPreview, tostring(ok), logEntry.returnsPreview or ""))
                if ok then
                    return r1, r2, r3
                else
                    error(logEntry.error)
                end
            else
                local ok, err = pcall(old, self, ...)
                logEntry.fireSuccess = ok
                if not ok then logEntry.error = tostring(err) end
                push_log(logEntry)
                print(("[LASSO-SPY] %s -> %s | args=[%s] | ok=%s"):format(logEntry.receiver, method, logEntry.argsPreview, tostring(ok)))
                return
            end
        end
        return old(self, ...)
    end)
    hooked = true
end

-- ====== hook strategy B: raw metatable fallback (only if needed) ======
if not hooked and has.getrawmetatable then
    local mt = getrawmetatable(game)
    if mt and type(mt.__namecall) == "function" then
        local oldNamecall = mt.__namecall
        if has.setreadonly then setreadonly(mt, false) end
        mt.__namecall = (has.newcclosure and newcclosure or function(f) return f end)(function(self, ...)
            local method = getnc()
            if isUnderTarget(self) and (method == "FireServer" or method == "FireClient" or method == "FireAllClients" or method == "InvokeServer" or method == "InvokeClient") then
                local packed = table.pack(...)
                local logEntry = {
                    time = os.time(),
                    method = method,
                    receiver = self and self:GetFullName() or tostring(self),
                    class = self and self.ClassName or "Unknown",
                    argsPreview = argsPreview(packed),
                    callerStack = captureStack(),
                    originIsScript = isCaller(),
                }
                if method:sub(1,6) == "Invoke" then
                    local ok, r1, r2, r3 = pcall(oldNamecall, self, ...)
                    logEntry.invokeSuccess = ok
                    if ok then
                        logEntry.returnsPreview = argsPreview(table.pack(r1, r2, r3))
                    else
                        logEntry.error = tostring(r1)
                    end
                    push_log(logEntry)
                    print(("[LASSO-SPY] %s -> %s | args=[%s] | ok=%s | ret=[%s]"):format(logEntry.receiver, method, logEntry.argsPreview, tostring(ok), logEntry.returnsPreview or ""))
                    if ok then
                        return r1, r2, r3
                    else
                        error(logEntry.error)
                    end
                else
                    local ok, err = pcall(oldNamecall, self, ...)
                    logEntry.fireSuccess = ok
                    if not ok then logEntry.error = tostring(err) end
                    push_log(logEntry)
                    print(("[LASSO-SPY] %s -> %s | args=[%s] | ok=%s"):format(logEntry.receiver, method, logEntry.argsPreview, tostring(ok)))
                    return
                end
            end
            return oldNamecall(self, ...)
        end)
        if has.setreadonly then setreadonly(mt, true) end
        hooked = true
    end
end

if not hooked then
    warn("[LASSO-SPY] Could not hook __namecall (no hookmetamethod and raw mt unsafe). Your executor may not support this.")
else
    print("[LASSO-SPY] Hook active. Watching remotes under: " .. target:GetFullName())
end

-- notify when new remotes appear
target.DescendantAdded:Connect(function(d)
    if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
        print("[LASSO-SPY] New remote: " .. d:GetFullName() .. " (" .. d.ClassName .. ")")
    end
end)

-- handy globals
_G.LassoSpyGetLogs = function(max)
    max = max or 50
    local out = {}
    for i=1, math.min(max, #_G.__LASSO_SPY_LOGS) do
        out[i] = _G.__LASSO_SPY_LOGS[i]
    end
    return out
end
_G.LassoSpyDump = function(depth)
    depth = depth or 4
    lightDump(target, depth, "")
end
