-- AutoJoiner.lua — GaG2 Wild Pet Finder + Auto Join
-- Scans current server AND polls your API for bot reports. Beautiful dark UI.

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local TeleportService  = game:GetService("TeleportService")
local Workspace        = game:GetService("Workspace")
local HttpService      = game:GetService("HttpService")
local LocalPlayer      = Players.LocalPlayer
local _cloneref        = typeof(cloneref) == "function" and cloneref or function(x) return x end

-- ── Anti-detect ──────────────────────────────────────────────────────────────
task.spawn(function()
    local _gs = _cloneref(game:GetService("GuiService"))
    local _rs = _cloneref(game:GetService("RunService"))
    local _f  = 0
    _rs.Heartbeat:Connect(function()
        _f = _f + 1; if _f < 3 then return end; _f = 0
        pcall(function() _gs:ClearError() end)
    end)
end)

-- ── Config ───────────────────────────────────────────────────────────────────
local CFG = {
    apiBase       = "",          -- e.g. "https://your-app.railway.app"
    pollInterval  = 6,           -- seconds between API polls
    scanInterval  = 1.5,         -- seconds between local workspace scans
    minValue      = 0,           -- hide pets below this value ($)
    placeId       = 97598239454123,
    autoTp        = false,       -- auto-teleport to LOCAL pets
    autoJoin      = false,       -- auto-teleport to API-reported pets
    notifyAll     = false,       -- scan all named models, not just the list
    tpMethodIdx   = 1,
    antiRollback  = true,
    arTolerance   = 8,
    arHoldFrames  = 40,
    arMaxAttempts = 3,
    notifyList    = {
        "frog", "bunny", "rabbit", "cat", "dog", "bee", "butterfly",
        "snail", "bird", "owl", "fox", "deer", "squirrel", "hedgehog",
        "ladybug", "turtle", "duck", "firefly", "mantis", "axolotl",
        "golden", "rainbow", "shiny",
    },
}

-- ── Helpers ──────────────────────────────────────────────────────────────────
local _httpReq = (syn and syn.request)
    or (http and http.request)
    or (rawget(_G, "request"))
    or (fluxus and fluxus.request)

local function cleanName(raw) return (raw:gsub("^[Ww][Ii][Ll][Dd]%s*", "")) end

local function parseValue(str)
    local s = (str or ""):gsub("[,%s¢%$]", "")
    local num = tonumber(s:match("[%d%.]+"))
    if not num then return 0 end
    local suf = s:match("[KkMmBbTt]$")
    if suf then
        suf = suf:lower()
        num = num * ((suf=="k" and 1e3) or (suf=="m" and 1e6) or (suf=="b" and 1e9) or (suf=="t" and 1e12) or 1)
    end
    return num
end

local function formatValue(v)
    if not v or v <= 0 then return "0" end
    if v >= 1e12 then return string.format("%.2fT", v/1e12) end
    if v >= 1e9  then return string.format("%.2fB", v/1e9)  end
    if v >= 1e6  then return string.format("%.2fM", v/1e6)  end
    if v >= 1e3  then return string.format("%.1fK", v/1e3)  end
    return tostring(math.floor(v))
end

local PET_EMOJI = {
    frog="🐸", bunny="🐰", rabbit="🐰", owl="🦉", bee="🐝",
    butterfly="🦋", snail="🐌", fox="🦊", deer="🦌", squirrel="🐿️",
    cat="🐱", dog="🐶", bird="🐦", duck="🦆", turtle="🐢",
    hedgehog="🦔", ladybug="🐞", firefly="✨", mantis="🦗",
    axolotl="🦎", golden="⭐", rainbow="🌈", shiny="💎",
}
local function petEmoji(name)
    local low = name:lower()
    for k, e in pairs(PET_EMOJI) do if low:find(k, 1, true) then return e end end
    return "🐾"
end

local function isTracked(name)
    if CFG.notifyAll then return true end
    local low = name:lower()
    for _, pat in ipairs(CFG.notifyList) do if low:find(pat, 1, true) then return true end end
    return false
end

-- ── Local Scanner ─────────────────────────────────────────────────────────────
local SPAWN_FOLDERS = {
    "WildPetSpawns", "WildPetSpawn", "WildAnimals", "Animals",
    "WildSpawns",    "Pets",         "NPCs",         "Spawns",
    "Temporary",     "Critters",     "GardenPets",
}

local function getValue(model)
    local best = 0
    for _, lbl in ipairs(model:GetDescendants()) do
        if lbl:IsA("TextLabel") then
            local t = lbl.Text
            if t:find("[¢%$]") or t:lower():find("sheckle") or t:match("%d%s?[KkMmBbTt]%f[%A]") then
                local v = parseValue(t); if v > best then best = v end
            end
        end
    end
    return best
end

local function getTimeLabel(model)
    for _, bb in ipairs(model:GetDescendants()) do
        if bb:IsA("BillboardGui") then
            for _, lbl in ipairs(bb:GetDescendants()) do
                if lbl:IsA("TextLabel") then
                    local t = lbl.Text
                    if t:match("%d+m%s*%d+s") or t:match("^%d+s$") or t:match("^%d+:%d+$") then return t end
                end
            end
        end
    end
    for _, lbl in ipairs(model:GetDescendants()) do
        if lbl:IsA("TextLabel") then
            local t = lbl.Text
            if t:match("%d+m%s*%d+s") then return t end
            if #t <= 8 and t:match("%d") and (t:find("s") or t:match("^%d+$")) and not t:find("[¢%$]") then return t end
        end
    end
    return "Active"
end

local function scanPets()
    local found, seen = {}, {}
    local function addFrom(container)
        for _, child in ipairs(container:GetChildren()) do
            local key = tostring(child)
            if not seen[key] then
                seen[key] = true
                local part = child:IsA("BasePart") and child
                    or child:FindFirstChild("HumanoidRootPart")
                    or child:FindFirstChildWhichIsA("BasePart")
                if part then
                    table.insert(found, {
                        source   = "local",
                        rawName  = child.Name,
                        name     = cleanName(child.Name),
                        instance = child,
                        cf       = part.CFrame,
                        pos      = part.Position,
                        value    = getValue(child),
                        time     = getTimeLabel(child),
                        jobId    = game.JobId,
                    })
                end
            end
        end
    end
    for _, fname in ipairs(SPAWN_FOLDERS) do
        local folder = Workspace:FindFirstChild(fname)
        if folder then addFrom(folder) end
    end
    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc.Name == "WildPetSpawns" or desc.Name == "WildPetSpawn" then addFrom(desc) end
    end
    table.sort(found, function(a, b) return (a.value or 0) > (b.value or 0) end)
    return found
end

-- ── TP Engine ────────────────────────────────────────────────────────────────
local TP_METHODS = {
    { id = "auto",     name = "Auto (Best)"   },
    { id = "cframe",   name = "CFrame Instant"},
    { id = "glide",    name = "CFrame Glide"  },
    { id = "velocity", name = "Velocity"      },
    { id = "hybrid",   name = "Hybrid"        },
    { id = "align",    name = "AlignPosition" },
    { id = "bodyvel",  name = "BodyVelocity"  },
    { id = "tween",    name = "TweenService"  },
}
local function _move_cframe(hrp, dest)
    hrp.AssemblyLinearVelocity = Vector3.zero; hrp.AssemblyAngularVelocity = Vector3.zero
    pcall(function() hrp.CFrame = dest end); RunService.Heartbeat:Wait(); hrp.AssemblyLinearVelocity = Vector3.zero
end
local function _move_glide(hrp, dest)
    local start = hrp.CFrame
    for i = 1, 20 do
        if not hrp.Parent then break end
        local t = i / 20; t = t*t*(3-2*t)
        pcall(function() hrp.CFrame = start:Lerp(dest, t) end)
        hrp.AssemblyLinearVelocity = Vector3.zero; RunService.Heartbeat:Wait()
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
end
local function _move_velocity(hrp, dest)
    local done, conn = false, nil
    conn = RunService.Heartbeat:Connect(function()
        if not hrp or not hrp.Parent or done then if conn then conn:Disconnect() end; return end
        local diff = dest.Position - hrp.Position
        if diff.Magnitude < 3 then
            done = true; conn:Disconnect(); pcall(function() hrp.CFrame = dest end)
            hrp.AssemblyLinearVelocity = Vector3.zero; return
        end
        hrp.AssemblyLinearVelocity = diff.Unit * math.min(400, diff.Magnitude * 10)
    end)
    local t0 = os.clock()
    while not done and os.clock()-t0 < 6 do task.wait(0.04) end
    if conn then pcall(function() conn:Disconnect() end) end
    hrp.AssemblyLinearVelocity = Vector3.zero
end
local function _move_hybrid(hrp, dest)
    if (dest.Position - hrp.Position).Magnitude > 40 then
        local done, conn = false, nil
        conn = RunService.Heartbeat:Connect(function()
            if not hrp or not hrp.Parent or done then if conn then conn:Disconnect() end; return end
            local diff = dest.Position - hrp.Position
            if diff.Magnitude < 12 then done = true; conn:Disconnect(); return end
            hrp.AssemblyLinearVelocity = diff.Unit * math.min(380, diff.Magnitude * 9)
        end)
        local t0 = os.clock()
        while not done and os.clock()-t0 < 5 do task.wait(0.04) end
        if conn then pcall(function() conn:Disconnect() end) end
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    pcall(function() hrp.CFrame = dest end); hrp.AssemblyLinearVelocity = Vector3.zero; RunService.Heartbeat:Wait()
end
local function _move_tween(hrp, dest)
    local tw = TweenService:Create(hrp, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {CFrame=dest})
    tw:Play(); tw.Completed:Wait(); hrp.AssemblyLinearVelocity = Vector3.zero
end
local MOVE_FNS = { cframe=_move_cframe, glide=_move_glide, velocity=_move_velocity, hybrid=_move_hybrid, tween=_move_tween }
local AUTO_ORDER = { "cframe", "hybrid", "velocity", "glide", "tween" }

local function holdPosition(hrp, dest, TOL, frames)
    local held = 0
    for _ = 1, frames do
        local ch = LocalPlayer.Character; hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then break end
        if (hrp.Position - dest.Position).Magnitude > TOL then
            pcall(function() hrp.CFrame = dest end)
            hrp.AssemblyLinearVelocity = Vector3.zero; hrp.AssemblyAngularVelocity = Vector3.zero
        else held = held + 1 end
        RunService.Heartbeat:Wait()
    end
    return held
end

local function tpTo(targetCF, onStatus)
    local function stat(t) if onStatus then onStatus(t) end end
    local ch = LocalPlayer.Character; local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hrp or not hrp.Parent then return false end
    local dest = targetCF * CFrame.new(0, 3, 0)
    local TOL = CFG.arTolerance; local thresh = math.floor(CFG.arHoldFrames * 0.4)
    local methodId = TP_METHODS[CFG.tpMethodIdx].id
    local attempts = {}
    if methodId == "auto" then for _, id in ipairs(AUTO_ORDER) do attempts[#attempts+1] = id end
    else
        attempts[#attempts+1] = methodId
        for _, id in ipairs(AUTO_ORDER) do if id ~= methodId then attempts[#attempts+1] = id end end
    end
    for pass = 1, CFG.arMaxAttempts do
        ch = LocalPlayer.Character; hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then return false end
        local m = attempts[((pass-1) % #attempts) + 1]
        stat("Attempt " .. pass .. " — " .. m)
        local fn = MOVE_FNS[m]; if fn then pcall(fn, hrp, dest) end
        ch = LocalPlayer.Character; hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then return false end
        if not CFG.antiRollback then
            if (hrp.Position - dest.Position).Magnitude <= TOL then return true end
        else
            local held = holdPosition(hrp, dest, TOL, CFG.arHoldFrames)
            ch = LocalPlayer.Character; hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            local finalD = (hrp and hrp.Parent) and (hrp.Position - dest.Position).Magnitude or math.huge
            if finalD <= TOL and held >= thresh then return true end
        end
        task.wait(0.08)
    end
    return false
end

-- ── State ─────────────────────────────────────────────────────────────────────
local _sentOnce      = {}   -- local dedup (petName|X|Z)
local _apiJoinedOnce = {}   -- API dedup (jobId|petName)
local lastLocalPet   = nil
local lastApiPet     = nil
local tpBusy         = false
local apiPets        = {}   -- latest /api/pets results

local function localPetKey(p)
    return p.name .. "|" .. tostring(math.round(p.pos.X)) .. "|" .. tostring(math.round(p.pos.Z))
end
local function apiPetKey(p)
    return (p.jobId or "") .. "|" .. (p.pet and p.pet.name or "")
end

-- ── API Poll ──────────────────────────────────────────────────────────────────
local function fetchApiPets()
    if CFG.apiBase == "" or not _httpReq then return {} end
    local result = {}
    pcall(function()
        local res = _httpReq({
            Url     = CFG.apiBase .. "/api/pets?minValue=" .. CFG.minValue,
            Method  = "GET",
            Headers = { ["User-Agent"] = "GaG2-AutoJoiner" },
        })
        if res and res.Body then
            local ok, d = pcall(function() return HttpService:JSONDecode(res.Body) end)
            if ok and d and d.pets then result = d.pets end
        end
    end)
    return result
end

-- ── UI ───────────────────────────────────────────────────────────────────────
do
    local ParentUI
    local ok = pcall(function() ParentUI = game:GetService("CoreGui") end)
    if not ok or not ParentUI then ParentUI = LocalPlayer:WaitForChild("PlayerGui") end
    if ParentUI:FindFirstChild("GaG2_AJ_Gui") then ParentUI.GaG2_AJ_Gui:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name = "GaG2_AJ_Gui"; sg.ResetOnSpawn = false; sg.IgnoreGuiInset = true
    sg.DisplayOrder = 999999; sg.Parent = ParentUI

    local C = {
        card    = Color3.fromRGB(8,   8,   10),
        surface = Color3.fromRGB(18,  18,  22),
        surfHi  = Color3.fromRGB(28,  28,  36),
        accent  = Color3.fromRGB(168, 85,  247),
        accent2 = Color3.fromRGB(205, 150, 255),
        txt     = Color3.fromRGB(238, 232, 255),
        txtSub  = Color3.fromRGB(175, 162, 210),
        txtMute = Color3.fromRGB(90,  80,  120),
        green   = Color3.fromRGB(70,  220, 150),
        red     = Color3.fromRGB(235, 80,  95),
        yellow  = Color3.fromRGB(245, 200, 80),
        orange  = Color3.fromRGB(245, 160, 60),
        knob    = Color3.fromRGB(220, 200, 255),
        local_  = Color3.fromRGB(70,  220, 150),  -- green for local finds
        remote_ = Color3.fromRGB(168, 85,  247),  -- purple for API finds
    }

    local W = 320

    local card = Instance.new("Frame", sg)
    card.Size = UDim2.new(0, W, 0, 520)
    card.Position = UDim2.new(0.5, -(W + 12), 0.28, 0)
    card.BackgroundColor3 = C.card; card.BorderSizePixel = 0
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 14)
    local cs = Instance.new("UIStroke", card); cs.Thickness = 1; cs.Color = C.accent; cs.Transparency = 0.45

    local HDR_H = 42; local PAD = 8

    -- Header
    local hdr = Instance.new("Frame", card)
    hdr.Size = UDim2.new(1, 0, 0, HDR_H); hdr.BackgroundColor3 = C.surface; hdr.BorderSizePixel = 0
    Instance.new("UICorner", hdr).CornerRadius = UDim.new(0, 14)
    local hsq = Instance.new("Frame", hdr)
    hsq.Size = UDim2.new(1, 0, 0, 14); hsq.Position = UDim2.new(0, 0, 1, -14)
    hsq.BackgroundColor3 = C.surface; hsq.BorderSizePixel = 0

    local titleLbl = Instance.new("TextLabel", hdr)
    titleLbl.Size = UDim2.new(1, 0, 1, 0); titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🌱  GaG2 AUTO JOIN"; titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 13; titleLbl.TextColor3 = C.accent; titleLbl.TextXAlignment = Enum.TextXAlignment.Center

    local detBadge = Instance.new("TextLabel", hdr)
    detBadge.Size = UDim2.new(0, 52, 0, 18); detBadge.Position = UDim2.new(0, 8, 0.5, -9)
    detBadge.BackgroundColor3 = C.surfHi; detBadge.BorderSizePixel = 0
    detBadge.Text = "0 found"; detBadge.Font = Enum.Font.GothamBold; detBadge.TextSize = 9
    detBadge.TextColor3 = C.accent2
    Instance.new("UICorner", detBadge).CornerRadius = UDim.new(0, 5)

    local minBtn = Instance.new("TextButton", hdr)
    minBtn.Size = UDim2.new(0, 26, 0, 26); minBtn.Position = UDim2.new(1, -33, 0.5, -13)
    minBtn.BackgroundColor3 = C.surfHi; minBtn.BorderSizePixel = 0
    minBtn.Text = "−"; minBtn.Font = Enum.Font.GothamBold; minBtn.TextSize = 15
    minBtn.TextColor3 = C.txtSub; minBtn.AutoButtonColor = false
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 7)

    -- Body area (fixed controls above scrollable list)
    local controls = Instance.new("Frame", card)
    controls.BackgroundTransparency = 1; controls.BorderSizePixel = 0
    controls.Position = UDim2.new(0, PAD, 0, HDR_H + PAD)
    controls.Size = UDim2.new(1, -PAD*2, 0, 0)
    local ctrlLayout = Instance.new("UIListLayout", controls)
    ctrlLayout.Padding = UDim.new(0, 5); ctrlLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ctrlLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    local function mkCtrlRow(order, h)
        local f = Instance.new("Frame", controls)
        f.Size = UDim2.new(1, 0, 0, h or 30); f.BackgroundColor3 = C.surface
        f.BorderSizePixel = 0; f.LayoutOrder = order
        Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
        return f
    end
    local function mkSwitch(parent, xRight, state)
        local sw = Instance.new("TextButton", parent)
        sw.Size = UDim2.new(0, 40, 0, 20); sw.Position = UDim2.new(1, xRight, 0.5, -10)
        sw.BackgroundColor3 = state and C.accent or C.surfHi; sw.BorderSizePixel = 0
        sw.Text = ""; sw.AutoButtonColor = false
        Instance.new("UICorner", sw).CornerRadius = UDim.new(1, 0)
        local dot = Instance.new("Frame", sw)
        dot.Size = UDim2.new(0, 14, 0, 14)
        dot.Position = state and UDim2.new(1,-17,0.5,-7) or UDim2.new(0,3,0.5,-7)
        dot.BackgroundColor3 = C.knob; dot.BorderSizePixel = 0
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
        local function toggle(v)
            sw.BackgroundColor3 = v and C.accent or C.surfHi
            dot.Position = v and UDim2.new(1,-17,0.5,-7) or UDim2.new(0,3,0.5,-7)
        end
        return sw, dot, toggle
    end
    local function mkCtrlLabel(parent, txt, col)
        local l = Instance.new("TextLabel", parent)
        l.Size = UDim2.new(1, -60, 1, 0); l.Position = UDim2.new(0, 10, 0, 0)
        l.BackgroundTransparency = 1; l.Text = txt
        l.Font = Enum.Font.GothamMedium; l.TextSize = 10; l.TextColor3 = col or C.txtSub
        l.TextXAlignment = Enum.TextXAlignment.Left
        return l
    end

    -- Status row (LO=1)
    local stRow = mkCtrlRow(1, 26)
    local stDot = Instance.new("Frame", stRow)
    stDot.Size = UDim2.new(0, 7, 0, 7); stDot.Position = UDim2.new(0, 10, 0.5, -3.5)
    stDot.BackgroundColor3 = C.txtMute; stDot.BorderSizePixel = 0
    Instance.new("UICorner", stDot).CornerRadius = UDim.new(1, 0)
    local stLbl = Instance.new("TextLabel", stRow)
    stLbl.Size = UDim2.new(1, -24, 1, 0); stLbl.Position = UDim2.new(0, 22, 0, 0)
    stLbl.BackgroundTransparency = 1; stLbl.Text = "Idle"
    stLbl.Font = Enum.Font.GothamMedium; stLbl.TextSize = 10; stLbl.TextColor3 = C.txtSub
    stLbl.TextXAlignment = Enum.TextXAlignment.Left; stLbl.TextTruncate = Enum.TextTruncate.AtEnd

    local totalFound = 0
    local function setStatus(t, c)
        stLbl.Text = t; stLbl.TextColor3 = c or C.txtSub; stDot.BackgroundColor3 = c or C.txtMute
    end

    -- API URL (LO=2)
    local aRow = mkCtrlRow(2, 32)
    local aBox = Instance.new("TextBox", aRow)
    aBox.Size = UDim2.new(1, -60, 1, -8); aBox.Position = UDim2.new(0, 7, 0, 4)
    aBox.BackgroundColor3 = C.surfHi; aBox.BorderSizePixel = 0
    aBox.Text = CFG.apiBase; aBox.PlaceholderText = "https://your-app.railway.app"
    aBox.Font = Enum.Font.Gotham; aBox.TextSize = 9; aBox.TextColor3 = C.txt
    aBox.ClearTextOnFocus = false; aBox.TextXAlignment = Enum.TextXAlignment.Left
    aBox.TextTruncate = Enum.TextTruncate.AtEnd
    Instance.new("UICorner", aBox).CornerRadius = UDim.new(0, 6)
    Instance.new("UIPadding", aBox).PaddingLeft = UDim.new(0, 7)
    aBox.FocusLost:Connect(function() CFG.apiBase = aBox.Text end)
    local aTest = Instance.new("TextButton", aRow)
    aTest.Size = UDim2.new(0, 44, 1, -8); aTest.Position = UDim2.new(1, -50, 0, 4)
    aTest.BackgroundColor3 = C.accent; aTest.BorderSizePixel = 0; aTest.Text = "Test"
    aTest.Font = Enum.Font.GothamBold; aTest.TextSize = 10; aTest.TextColor3 = C.txt; aTest.AutoButtonColor = false
    Instance.new("UICorner", aTest).CornerRadius = UDim.new(0, 6)
    aTest.MouseButton1Click:Connect(function()
        CFG.apiBase = aBox.Text
        if CFG.apiBase == "" then setStatus("Enter API URL first", C.red); return end
        setStatus("Testing…", C.yellow)
        task.spawn(function()
            local ok = false
            pcall(function()
                local res = _httpReq({ Url = CFG.apiBase .. "/stats", Method = "GET",
                    Headers = { ["User-Agent"] = "GaG2-AJ-test" } })
                ok = res and res.StatusCode == 200
            end)
            setStatus(ok and "✔ API connected!" or "✘ Connection failed", ok and C.green or C.red)
        end)
    end)

    -- Min value row (LO=3)
    local mvRow = mkCtrlRow(3, 28)
    mkCtrlLabel(mvRow, "Min Value ($)", C.txtSub)
    local mvBox = Instance.new("TextBox", mvRow)
    mvBox.Size = UDim2.new(0, 72, 0, 18); mvBox.Position = UDim2.new(1, -80, 0.5, -9)
    mvBox.BackgroundColor3 = C.surfHi; mvBox.BorderSizePixel = 0
    mvBox.Text = tostring(CFG.minValue); mvBox.Font = Enum.Font.GothamBold; mvBox.TextSize = 11
    mvBox.TextColor3 = C.accent2; mvBox.TextXAlignment = Enum.TextXAlignment.Center
    mvBox.ClearTextOnFocus = false
    Instance.new("UICorner", mvBox).CornerRadius = UDim.new(0, 5)
    mvBox.FocusLost:Connect(function()
        local v = tonumber(mvBox.Text); if v then CFG.minValue = math.max(0, math.floor(v)) end
        mvBox.Text = tostring(CFG.minValue)
    end)

    -- Auto-TP local (LO=4)
    local atRow = mkCtrlRow(4, 28); mkCtrlLabel(atRow, "Auto-TP (local pets)", C.local_)
    local atSw, _, atToggle = mkSwitch(atRow, -48, CFG.autoTp)
    atSw.MouseButton1Click:Connect(function() CFG.autoTp = not CFG.autoTp; atToggle(CFG.autoTp) end)

    -- Auto-Join API (LO=5)
    local ajRow = mkCtrlRow(5, 28); mkCtrlLabel(ajRow, "Auto-Join (API pets)", C.remote_)
    local ajSw, _, ajToggle = mkSwitch(ajRow, -48, CFG.autoJoin)
    ajSw.MouseButton1Click:Connect(function() CFG.autoJoin = not CFG.autoJoin; ajToggle(CFG.autoJoin) end)

    -- Notify All (LO=6)
    local naRow = mkCtrlRow(6, 28); mkCtrlLabel(naRow, "Notify all pets", C.txtSub)
    local naSw, _, naToggle = mkSwitch(naRow, -48, CFG.notifyAll)
    naSw.MouseButton1Click:Connect(function() CFG.notifyAll = not CFG.notifyAll; naToggle(CFG.notifyAll) end)

    -- TP method (LO=7)
    local mRow = mkCtrlRow(7, 32)
    local mLbl2 = Instance.new("TextLabel", mRow)
    mLbl2.Size = UDim2.new(0, 72, 1, 0); mLbl2.Position = UDim2.new(0, 10, 0, 0)
    mLbl2.BackgroundTransparency = 1; mLbl2.Text = "TP Method"
    mLbl2.Font = Enum.Font.GothamBold; mLbl2.TextSize = 10; mLbl2.TextColor3 = C.txtMute
    mLbl2.TextXAlignment = Enum.TextXAlignment.Left
    local mPrev2 = Instance.new("TextButton", mRow)
    mPrev2.Size = UDim2.new(0, 22, 0, 22); mPrev2.Position = UDim2.new(0, 84, 0.5, -11)
    mPrev2.BackgroundColor3 = C.surfHi; mPrev2.BorderSizePixel = 0; mPrev2.Text = "◄"
    mPrev2.Font = Enum.Font.GothamBold; mPrev2.TextSize = 10; mPrev2.TextColor3 = C.accent; mPrev2.AutoButtonColor = false
    Instance.new("UICorner", mPrev2).CornerRadius = UDim.new(0, 6)
    local mVal2 = Instance.new("TextLabel", mRow)
    mVal2.Size = UDim2.new(0, 106, 1, 0); mVal2.Position = UDim2.new(0, 108, 0, 0)
    mVal2.BackgroundTransparency = 1; mVal2.Text = TP_METHODS[CFG.tpMethodIdx].name
    mVal2.Font = Enum.Font.GothamMedium; mVal2.TextSize = 10; mVal2.TextColor3 = C.accent2
    mVal2.TextXAlignment = Enum.TextXAlignment.Center
    local mNext2 = Instance.new("TextButton", mRow)
    mNext2.Size = UDim2.new(0, 22, 0, 22); mNext2.Position = UDim2.new(1, -30, 0.5, -11)
    mNext2.BackgroundColor3 = C.surfHi; mNext2.BorderSizePixel = 0; mNext2.Text = "►"
    mNext2.Font = Enum.Font.GothamBold; mNext2.TextSize = 10; mNext2.TextColor3 = C.accent; mNext2.AutoButtonColor = false
    Instance.new("UICorner", mNext2).CornerRadius = UDim.new(0, 6)
    mPrev2.MouseButton1Click:Connect(function() CFG.tpMethodIdx = ((CFG.tpMethodIdx-2) % #TP_METHODS)+1; mVal2.Text = TP_METHODS[CFG.tpMethodIdx].name end)
    mNext2.MouseButton1Click:Connect(function() CFG.tpMethodIdx = (CFG.tpMethodIdx % #TP_METHODS)+1; mVal2.Text = TP_METHODS[CFG.tpMethodIdx].name end)

    -- Action buttons row (LO=8)
    local actOuter = Instance.new("Frame", controls)
    actOuter.Size = UDim2.new(1, 0, 0, 30); actOuter.BackgroundTransparency = 1; actOuter.LayoutOrder = 8
    local actL = Instance.new("UIListLayout", actOuter)
    actL.FillDirection = Enum.FillDirection.Horizontal; actL.Padding = UDim.new(0, 5)
    actL.HorizontalAlignment = Enum.HorizontalAlignment.Center; actL.VerticalAlignment = Enum.VerticalAlignment.Center

    local function mkActBtn(txt, bg)
        local b = Instance.new("TextButton", actOuter)
        b.Size = UDim2.new(0.5, -4, 1, 0); b.BackgroundColor3 = bg; b.BorderSizePixel = 0
        b.AutoButtonColor = false; b.Text = txt
        b.Font = Enum.Font.GothamBold; b.TextSize = 11; b.TextColor3 = C.txt
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        b.MouseEnter:Connect(function() b.BackgroundColor3 = bg:Lerp(Color3.new(1,1,1), 0.12) end)
        b.MouseLeave:Connect(function() b.BackgroundColor3 = bg end)
        return b
    end
    local tpLastBtn  = mkActBtn("⚡ TP Last",    C.local_)
    local joinBestBtn = mkActBtn("🔗 Join Best", C.accent)

    -- Section label (LO=9)
    local sectRow = mkCtrlRow(9, 22)
    sectRow.BackgroundColor3 = Color3.fromRGB(0,0,0); sectRow.BackgroundTransparency = 1
    local sectLbl = Instance.new("TextLabel", sectRow)
    sectLbl.Size = UDim2.new(1,0,1,0); sectLbl.BackgroundTransparency = 1
    sectLbl.Text = "● LOCAL   🟣 API BOTS"; sectLbl.Font = Enum.Font.GothamBold
    sectLbl.TextSize = 9; sectLbl.TextColor3 = C.txtMute; sectLbl.TextXAlignment = Enum.TextXAlignment.Left
    sectLbl.Position = UDim2.new(0,0,0,0)

    -- Scrollable pet list (LO=10)
    local listHolder = Instance.new("Frame", controls)
    listHolder.Size = UDim2.new(1, 0, 0, 200); listHolder.BackgroundColor3 = C.surface
    listHolder.BorderSizePixel = 0; listHolder.LayoutOrder = 10
    Instance.new("UICorner", listHolder).CornerRadius = UDim.new(0, 8)

    local scroll = Instance.new("ScrollingFrame", listHolder)
    scroll.Size = UDim2.new(1, -4, 1, -4); scroll.Position = UDim2.new(0, 2, 0, 2)
    scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4; scroll.ScrollBarImageColor3 = C.accent
    scroll.CanvasSize = UDim2.new(0,0,0,0); scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

    local listLayout = Instance.new("UIListLayout", scroll)
    listLayout.Padding = UDim.new(0, 3); listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    Instance.new("UIPadding", scroll).PaddingTop = UDim.new(0, 4)

    -- Footer
    local ftrLbl = Instance.new("TextLabel", card)
    ftrLbl.Size = UDim2.new(1, 0, 0, 18); ftrLbl.BackgroundTransparency = 1
    ftrLbl.Text = "GaG2 Auto Join"; ftrLbl.Font = Enum.Font.GothamBold; ftrLbl.TextSize = 9
    ftrLbl.TextColor3 = C.txtMute; ftrLbl.TextXAlignment = Enum.TextXAlignment.Center
    ftrLbl.Position = UDim2.new(0, 0, 1, -18)

    -- Resize card based on controls height
    local function resizeCard()
        local ctrlH = ctrlLayout.AbsoluteContentSize.Y
        controls.Size = UDim2.new(1, -PAD*2, 0, ctrlH)
        card.Size = UDim2.new(0, W, 0, HDR_H + PAD + ctrlH + PAD + 18)
    end
    ctrlLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resizeCard)
    task.defer(resizeCard)

    local minimized = false
    local function setMinimized(m)
        minimized = m; controls.Visible = not m
        if m then
            card.Size = UDim2.new(0, W, 0, HDR_H + 18)
            ftrLbl.Position = UDim2.new(0, 0, 1, -18)
            minBtn.Text = "+"
        else
            resizeCard(); minBtn.Text = "−"
        end
    end
    minBtn.MouseButton1Click:Connect(function() setMinimized(not minimized) end)

    -- Drag
    local dragging, dragStart, cardStart
    hdr.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = inp.Position; cardStart = card.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if not dragging then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then
            local d = inp.Position - dragStart
            card.Position = UDim2.new(cardStart.X.Scale, cardStart.X.Offset + d.X, cardStart.Y.Scale, cardStart.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)

    -- Pet row builder
    local petRows = {}
    local function clearPetList()
        for _, r in pairs(petRows) do pcall(function() r:Destroy() end) end
        petRows = {}
    end

    local function addPetRow(pet, index)
        local isLocal  = pet.source == "local"
        local srcColor = isLocal and C.local_ or C.remote_
        local srcDot   = isLocal and "●" or "🟣"
        local valStr   = "$" .. formatValue(pet.value or (pet.pet and pet.pet.value) or 0)
        local petName  = pet.name or (pet.pet and pet.pet.name) or "?"
        local timeStr  = pet.time or (pet.pet and pet.pet.time) or "?"
        local jobId    = pet.jobId or "?"
        local emoji    = petEmoji(petName)

        local row = Instance.new("Frame", scroll)
        row.Size = UDim2.new(1, -8, 0, 54); row.BackgroundColor3 = C.surfHi
        row.BorderSizePixel = 0; row.LayoutOrder = index
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)
        table.insert(petRows, row)

        -- Source indicator
        local srcDotLbl = Instance.new("TextLabel", row)
        srcDotLbl.Size = UDim2.new(0, 10, 0, 10); srcDotLbl.Position = UDim2.new(0, 6, 0, 4)
        srcDotLbl.BackgroundTransparency = 1; srcDotLbl.Text = "●"
        srcDotLbl.TextColor3 = srcColor; srcDotLbl.Font = Enum.Font.GothamBold; srcDotLbl.TextSize = 8

        -- Emoji
        local emojiLbl = Instance.new("TextLabel", row)
        emojiLbl.Size = UDim2.new(0, 30, 0, 40); emojiLbl.Position = UDim2.new(0, 8, 0, 7)
        emojiLbl.BackgroundTransparency = 1; emojiLbl.Text = emoji
        emojiLbl.TextSize = 22; emojiLbl.Font = Enum.Font.GothamBold
        emojiLbl.TextXAlignment = Enum.TextXAlignment.Left

        -- Name
        local nameLbl = Instance.new("TextLabel", row)
        nameLbl.Size = UDim2.new(0, 160, 0, 18); nameLbl.Position = UDim2.new(0, 40, 0, 6)
        nameLbl.BackgroundTransparency = 1; nameLbl.Text = petName
        nameLbl.Font = Enum.Font.GothamBold; nameLbl.TextSize = 11; nameLbl.TextColor3 = C.txt
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left; nameLbl.TextTruncate = Enum.TextTruncate.AtEnd

        -- Value badge
        local valBadge = Instance.new("TextLabel", row)
        valBadge.Size = UDim2.new(0, 68, 0, 18); valBadge.Position = UDim2.new(1, -75, 0, 6)
        valBadge.BackgroundColor3 = C.accent; valBadge.BorderSizePixel = 0
        valBadge.Text = valStr; valBadge.Font = Enum.Font.GothamBold; valBadge.TextSize = 10
        valBadge.TextColor3 = C.txt; valBadge.TextXAlignment = Enum.TextXAlignment.Center
        Instance.new("UICorner", valBadge).CornerRadius = UDim.new(0, 5)

        -- Time + job info
        local infoLbl = Instance.new("TextLabel", row)
        infoLbl.Size = UDim2.new(0, 200, 0, 13); infoLbl.Position = UDim2.new(0, 40, 0, 26)
        infoLbl.BackgroundTransparency = 1
        infoLbl.Text = "⏱ " .. timeStr .. "  🆔 " .. tostring(jobId):sub(1, 18) .. "…"
        infoLbl.Font = Enum.Font.Gotham; infoLbl.TextSize = 9; infoLbl.TextColor3 = C.txtMute
        infoLbl.TextXAlignment = Enum.TextXAlignment.Left; infoLbl.TextTruncate = Enum.TextTruncate.AtEnd

        -- TP / Join button
        local actionBtn = Instance.new("TextButton", row)
        actionBtn.Size = UDim2.new(0, 50, 0, 20); actionBtn.Position = UDim2.new(1, -58, 1, -26)
        actionBtn.BackgroundColor3 = isLocal and C.local_ or C.accent
        actionBtn.BorderSizePixel = 0; actionBtn.AutoButtonColor = false
        actionBtn.Text = isLocal and "TP" or "Join"; actionBtn.Font = Enum.Font.GothamBold
        actionBtn.TextSize = 10; actionBtn.TextColor3 = C.card
        Instance.new("UICorner", actionBtn).CornerRadius = UDim.new(0, 5)
        actionBtn.MouseEnter:Connect(function() actionBtn.BackgroundTransparency = 0.2 end)
        actionBtn.MouseLeave:Connect(function() actionBtn.BackgroundTransparency = 0 end)

        actionBtn.MouseButton1Click:Connect(function()
            if isLocal then
                -- TP to local pet
                if tpBusy then return end
                tpBusy = true
                setStatus("TP → " .. petName .. "…", C.yellow)
                task.spawn(function()
                    if pet.instance and pet.instance.Parent then
                        local part = pet.instance:IsA("BasePart") and pet.instance
                            or pet.instance:FindFirstChildWhichIsA("BasePart")
                        if part then pet.cf = part.CFrame end
                    end
                    local ok2 = tpTo(pet.cf, function(s) setStatus(s, C.txtSub) end)
                    setStatus(ok2 and ("✔ " .. petName) or ("✘ TP failed"), ok2 and C.green or C.red)
                    tpBusy = false
                end)
            else
                -- Teleport to remote server
                if not pet.jobId then setStatus("No Job ID", C.red); return end
                setStatus("Joining " .. petName .. "…", C.yellow)
                task.spawn(function()
                    local ok2 = pcall(function()
                        TeleportService:TeleportToPlaceInstance(CFG.placeId, pet.jobId)
                    end)
                    if not ok2 then setStatus("Teleport failed", C.red) end
                end)
            end
        end)
    end

    -- Rebuild the full pet list
    local function rebuildList(localPets, remotePets)
        clearPetList()
        local all = {}
        -- Add local pets
        for _, p in ipairs(localPets) do
            local val = p.value or 0
            if val >= CFG.minValue and isTracked(p.name) then
                table.insert(all, { source="local", name=p.name, value=val, time=p.time, jobId=p.jobId, cf=p.cf, pos=p.pos, instance=p.instance })
            end
        end
        -- Add remote pets
        for _, p in ipairs(remotePets) do
            local val = (p.pet and p.pet.value) or 0
            if val >= CFG.minValue then
                local pname = (p.pet and p.pet.name) or "?"
                table.insert(all, { source="api", name=pname, value=val, time=(p.pet and p.pet.time) or "?", jobId=p.jobId })
            end
        end
        -- Sort by value
        table.sort(all, function(a, b) return (a.value or 0) > (b.value or 0) end)
        totalFound = #all
        detBadge.Text = totalFound .. " found"
        for i, p in ipairs(all) do addPetRow(p, i) end
        if #all == 0 then
            local emptyLbl = Instance.new("TextLabel", scroll)
            emptyLbl.Size = UDim2.new(1, -8, 0, 36); emptyLbl.BackgroundTransparency = 1
            emptyLbl.Text = "No pets found yet"; emptyLbl.Font = Enum.Font.GothamMedium
            emptyLbl.TextSize = 11; emptyLbl.TextColor3 = C.txtMute; emptyLbl.LayoutOrder = 1
            table.insert(petRows, emptyLbl)
        end
    end

    -- Shared state
    local currentLocalPets = {}

    tpLastBtn.MouseButton1Click:Connect(function()
        if lastLocalPet then
            if tpBusy then return end
            tpBusy = true
            setStatus("TP Last → " .. lastLocalPet.name .. "…", C.yellow)
            task.spawn(function()
                if lastLocalPet.instance and lastLocalPet.instance.Parent then
                    local part = lastLocalPet.instance:IsA("BasePart") and lastLocalPet.instance
                        or lastLocalPet.instance:FindFirstChildWhichIsA("BasePart")
                    if part then lastLocalPet.cf = part.CFrame end
                end
                local ok2 = tpTo(lastLocalPet.cf, function(s) setStatus(s, C.txtSub) end)
                setStatus(ok2 and ("✔ " .. lastLocalPet.name) or "✘ TP failed", ok2 and C.green or C.red)
                tpBusy = false
            end)
        elseif lastApiPet then
            setStatus("Joining " .. (lastApiPet.pet and lastApiPet.pet.name or "?") .. "…", C.yellow)
            pcall(function() TeleportService:TeleportToPlaceInstance(CFG.placeId, lastApiPet.jobId) end)
        else
            setStatus("No pet detected yet", C.red)
        end
    end)

    joinBestBtn.MouseButton1Click:Connect(function()
        -- Find best API pet
        local best = nil
        for _, p in ipairs(apiPets) do
            if not best or (p.pet and p.pet.value or 0) > (best.pet and best.pet.value or 0) then
                best = p
            end
        end
        if best and best.jobId then
            setStatus("Joining best: " .. (best.pet and best.pet.name or "?"), C.yellow)
            pcall(function() TeleportService:TeleportToPlaceInstance(CFG.placeId, best.jobId) end)
        else
            setStatus("No API pets available", C.red)
        end
    end)

    -- Local scan loop
    task.spawn(function()
        while sg.Parent do
            pcall(function()
                local pets = scanPets()
                currentLocalPets = pets
                -- Auto-TP to first tracked pet found
                if CFG.autoTp and not tpBusy and #pets > 0 then
                    for _, p in ipairs(pets) do
                        if isTracked(p.name) and (p.value or 0) >= CFG.minValue then
                            local key = localPetKey(p)
                            if not _sentOnce[key] then
                                _sentOnce[key] = true
                                lastLocalPet = p
                                tpBusy = true
                                setStatus("Auto-TP → " .. p.name, C.yellow)
                                task.spawn(function()
                                    local ok2 = tpTo(p.cf, function(s) setStatus(s, C.txtSub) end)
                                    setStatus(ok2 and ("✔ " .. p.name) or "✘ TP failed", ok2 and C.green or C.red)
                                    tpBusy = false
                                end)
                                break
                            end
                        end
                    end
                end
                for _, p in ipairs(pets) do
                    if isTracked(p.name) and (p.value or 0) >= CFG.minValue then lastLocalPet = p end
                end
                rebuildList(currentLocalPets, apiPets)
                if #pets == 0 then setStatus("Scanning… no local pets", C.txtMute)
                else setStatus(#pets .. " local pet(s) found!", C.green) end
            end)
            task.wait(CFG.scanInterval)
        end
    end)

    -- API poll loop
    task.spawn(function()
        while sg.Parent do
            task.wait(CFG.pollInterval)
            if CFG.apiBase ~= "" then
                pcall(function()
                    local newPets = fetchApiPets()
                    apiPets = newPets
                    -- Auto-join best new API pet
                    if CFG.autoJoin and #newPets > 0 then
                        for _, p in ipairs(newPets) do
                            local key = apiPetKey(p)
                            if not _apiJoinedOnce[key] then
                                _apiJoinedOnce[key] = true
                                lastApiPet = p
                                local pname = (p.pet and p.pet.name) or "?"
                                setStatus("Auto-Join → " .. pname, C.yellow)
                                pcall(function() TeleportService:TeleportToPlaceInstance(CFG.placeId, p.jobId) end)
                                break
                            end
                        end
                    end
                    rebuildList(currentLocalPets, newPets)
                    if #newPets > 0 then
                        local pname = (newPets[1].pet and newPets[1].pet.name) or "?"
                        setStatus("API: " .. #newPets .. " pet(s) — best: " .. pname, C.accent2)
                    end
                end)
            end
        end
    end)

    -- Initial scan
    task.delay(0.5, function()
        pcall(function()
            local pets = scanPets()
            currentLocalPets = pets
            rebuildList(pets, {})
            setStatus("Ready — " .. #pets .. " local, API polling…", C.green)
        end)
    end)
end
