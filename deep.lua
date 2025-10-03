-- RemoteDeepSpy.client.lua
-- Logs client->server and server->client for specific remotes
local RS = game:GetService("ReplicatedStorage")
local SP = game:GetService("StarterPlayer")
local SG = game:GetService("StarterGui")

local RemotesFolder = RS:WaitForChild("Remotes")
local Replication = RS:FindFirstChild("_replicationFolder")

local TARGET_NAMES = {
    StoreAnimalRemote = true,
    SellSlotsRemote   = true,
    BlindPlayerRemote = true,
    ClientloaderRemote= true,
    Wildmode          = true,
    Unseat            = true,
}

-- ============== utils ==============
local function getFullName(inst)
    local parts = {}
    while inst do
        table.insert(parts, 1, inst.Name)
        inst = inst.Parent
    end
    return table.concat(parts, ".")
end

local function isTargetRemote(inst)
    if not inst then return false end
    if not (inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction")) then return false end
    if not (inst:IsDescendantOf(RS) or inst:IsDescendantOf(SP) or inst:IsDescendantOf(SG)) then return false end
    return TARGET_NAMES[inst.Name] == true
end

local function dump(val, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local pad = string.rep("  ", depth)
    local t = typeof(val)
    if t == "table" then
        if seen[val] then return pad.."{<cycle>}" end
        seen[val] = true
        local out = { pad.."{\n" }
        local n = 0
        for k,v in pairs(val) do
            n += 1
            table.insert(out, pad.."  ["..tostring(k).."("..typeof(k)..")] = "..dump(v, depth+1, seen).."\n")
        end
        table.insert(out, pad.."} -- items:"..n)
        return table.concat(out)
    elseif t == "Instance" then
        return ("%sInstance<%s>:%s"):format(pad, val.ClassName, getFullName(val))
    elseif t == "Vector3" or t == "CFrame" or t == "Color3" or t == "UDim2" then
        return pad..t.."("..tostring(val)..")"
    else
        return pad..t.."("..tostring(val)..")"
    end
end

-- Small ring buffer of last N calls for replay
local LOG = {}
local MAX_LOG = 100
local function pushLog(entry)
    table.insert(LOG, entry)
    if #LOG > MAX_LOG then table.remove(LOG, 1) end
end

_G.RemoteDeepSpy = {
    Log = LOG,
    Replay = function(i)
        local e = LOG[i]
        if not e then return warn("[Spy] No log at index", i) end
        if not e.remote or not e.remote.Parent then return warn("[Spy] Remote no longer exists") end
        if e.method == "FireServer" then
            print("[Spy] Replaying FireServer:", getFullName(e.remote))
            e.remote:FireServer(table.unpack(e.args))
        elseif e.method == "InvokeServer" then
            print("[Spy] Replaying InvokeServer:", getFullName(e.remote))
            local ok, res = pcall(function() return e.remote:InvokeServer(table.unpack(e.args)) end)
            print("[Spy] InvokeServer ok?", ok, "res:", res)
        else
            warn("[Spy] Unknown method", e.method)
        end
    end
}

-- ============== server->client listeners ==============
local function hookServerToClient(root)
    if not root then return end
    for _, inst in ipairs(root:GetDescendants()) do
        if isTargetRemote(inst) then
            if inst:IsA("RemoteEvent") then
                inst.OnClientEvent:Connect(function(...)
                    print(("\n[Spy] OnClientEvent <- %s"):format(getFullName(inst)))
                    local args = { ... }
                    for i,v in ipairs(args) do
                        print(("  arg[%d]: %s"):format(i, dump(v)))
                    end
                end)
            elseif inst:IsA("RemoteFunction") then
                inst.OnClientInvoke = function(...)
                    print(("\n[Spy] OnClientInvoke <- %s"):format(getFullName(inst)))
                    local args = { ... }
                    for i,v in ipairs(args) do
                        print(("  arg[%d]: %s"):format(i, dump(v)))
                    end
                    return nil -- return something benign if the server expects a value
                end
            end
        end
    end
    root.DescendantAdded:Connect(function(inst)
        if isTargetRemote(inst) and inst:IsA("RemoteEvent") then
            inst.OnClientEvent:Connect(function(...)
                print(("\n[Spy] OnClientEvent <- %s"):format(getFullName(inst)))
                local args = { ... }
                for i,v in ipairs(args) do
                    print(("  arg[%d]: %s"):format(i, dump(v)))
                end
            end)
        end
    end)
end

hookServerToClient(RS)
hookServerToClient(SP)
hookServerToClient(SG)
hookServerToClient(Replication)

-- ============== client->server spy via __namecall (if allowed) ==============
do
    local ok, mt = pcall(getrawmetatable, game)
    if ok and mt then
        local old = mt.__namecall
        local setro = (setreadonly or make_writeable or function() end)
        pcall(setro, mt, false)
        mt.__namecall = function(self, ...)
            local method = getnamecallmethod and getnamecallmethod() or ""
            if (method == "FireServer" or method == "InvokeServer") and isTargetRemote(self) then
                local args = { ... }
                print(("\n[Spy] %s -> %s"):format(method, getFullName(self)))
                for i,v in ipairs(args) do
                    print(("  arg[%d]: %s"):format(i, dump(v)))
                end
                pushLog({ remote = self, method = method, args = args })
            end
            return old(self, ...)
        end
        pcall(setro, mt, true)
        print("[Spy] __namecall hook active.")
    else
        print("[Spy] __namecall hook NOT available in this environment. You will still see server->client logs.")
    end
end

print("[Spy] Ready. Targets: StoreAnimalRemote, SellSlotsRemote, BlindPlayerRemote, ClientloaderRemote, Wildmode, Unseat")
