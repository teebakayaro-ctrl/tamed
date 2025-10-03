-- AutoTame v0.1 — reuse last _hit args, retarget to nearest horse, then call _hit
-- Requirements: You've already run HitCompact and got at least one [_hit] capture.

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- shallow copy
local function copy(t)
    if typeof(t) ~= "table" then return t end
    local r = {}
    for k,v in pairs(t) do r[k] = v end
    return r
end

-- find nearest Model that looks like a horse
local HORSE_HINTS = { "horse", "mustang", "stallion", "bronco" }
local function looksHorsey(model)
    local name = string.lower(model.Name or "")
    for _,h in ipairs(HORSE_HINTS) do
        if name:find(h, 1, true) then return true end
    end
    return false
end
local function nearestHorse()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local best, bestd = nil, math.huge
    for _, m in ipairs(workspace:GetDescendants()) do
        if m:IsA("Model") and looksHorsey(m) then
            local hrp = m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("UpperTorso") or m:FindFirstChild("Torso")
            if hrp and hrp:IsA("BasePart") then
                local d = (hrp.Position - root.Position).Magnitude
                if d < bestd then bestd, best = d, m end
            end
        end
    end
    return best
end

-- equip lasso if you have one
local function equipLasso()
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local function isLasso(tool)
        local n = (tool and tool.Name or ""):lower()
        return n:find("lasso",1,true) or n:find("rope",1,true)
    end
    if LocalPlayer.Character then
        for _,t in ipairs(LocalPlayer.Character:GetChildren()) do
            if t:IsA("Tool") and isLasso(t) then return t end
        end
    end
    if backpack then
        for _,t in ipairs(backpack:GetChildren()) do
            if t:IsA("Tool") and isLasso(t) then
                t.Parent = LocalPlayer.Character
                task.wait()
                return t
            end
        end
    end
end

-- build new args from the last captured _hit
local function buildArgsFor(horse)
    local last = _G.LASSO_LASTARGS__hit
    local hitFn = _G.__HitCompact_wrapped  -- original _hit function reference recorded by HitCompact
    if not last or not last.n or not hitFn then
        warn("[AutoTame] Need at least one [_hit] capture and HitCompact running.")
        return nil, nil
    end
    local a1 = copy(last[1] or {})
    local a2 = copy(last[2] or {})
    local hrp = horse and (horse:FindFirstChild("HumanoidRootPart") or horse:FindFirstChild("UpperTorso") or horse:FindFirstChild("Torso"))

    -- refresh obvious fields in a1 (your side)
    local char = LocalPlayer.Character
    if char then a1.Character = char end
    a1.Player = LocalPlayer
    a1.Owner  = a1.Owner or LocalPlayer

    -- ensure we have a lasso tool in a1 if the template had it
    if a1.Tool == nil then
        local tool = equipLasso()
        if tool then a1.Tool = tool end
    end

    -- refresh target fields in a2
    if horse then
        a2.Model = horse
        if hrp then
            a2.HumanoidRootPart = hrp
            a2.HRP = hrp
        end
    end

    -- new hit position
    local a3 = hrp and hrp.Position or last[3]

    return {a1, a2, a3}, hitFn
end

-- public: try to tame the nearest horse now
_G.AutoTameNearest = function()
    local horse = nearestHorse()
    if not horse then
        print("[AutoTame] No horse nearby.")
        return
    end
    equipLasso()
    local pack, hitFn = buildArgsFor(horse)
    if not pack then return end
    print(("[AutoTame] Calling _hit with: a1[tool=%s]  a2[model=%s]  a3=%s")
        :format(tostring(pack[1].Tool), tostring(pack[2].Model), tostring(pack[3])))
    -- call _hit (will also print one compact [_hit] line from the logger)
    local ok, err = pcall(function()
        return hitFn(pack[1], pack[2], pack[3])
    end)
    if not ok then
        warn("[AutoTame] _hit call failed: "..tostring(err))
    end
end

print("[AutoTame] Loaded. Type AutoTameNearest() when you’re near a horse.")
