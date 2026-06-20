-- WildPetWebhook.lua — GaG2 Wild Pet Scanner + Server Hopper + API Reporter
-- Scans Grow a Garden 2 for wild pets, reports to your hopper API & Discord, then hops to next server.

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local HttpService      = game:GetService("HttpService")
local TeleportService  = game:GetService("TeleportService")
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

task.spawn(function()
    local _GuiService = _cloneref(game:GetService("GuiService"))
    pcall(function()
        local mt = getrawmetatable(_GuiService)
        if not mt then return end
        local old = mt.__index
        if type(setreadonly) == "function" then setreadonly(mt, false) end
        mt.__index = newcclosure(function(s, k)
            if k == "SetErrorMessage" or k == "GetErrorMessage" then
                return newcclosure(function() return "" end)
            end
            return old(s, k)
        end)
        if type(setreadonly) == "function" then setreadonly(mt, true) end
    end)
    local KILL = { ErrorPrompt = true, RobloxPromptGui = true, PromptOverlay = true }
    local function nuke(d)
        pcall(function()
            if d:IsA("GuiObject") then d.Visible = false end
            if d:IsA("ScreenGui")  then d.Enabled = false end
            task.delay(2, function() pcall(function() d:Destroy() end) end)
        end)
    end
    pcall(function()
        game:GetService("CoreGui").DescendantAdded:Connect(function(d) if KILL[d.Name] then nuke(d) end end)
    end)
    pcall(function()
        local pg = LocalPlayer:WaitForChild("PlayerGui", 5)
        if pg then pg.DescendantAdded:Connect(function(d) if KILL[d.Name] then nuke(d) end end) end
    end)
    while true do pcall(function() _GuiService:ClearError() end); task.wait(0.1) end
end)

-- ── Config ───────────────────────────────────────────────────────────────────
local CFG = {
    -- API / hopper server (your Railway URL, no trailing slash)
    apiBase        = "",             -- e.g. "https://your-app.railway.app"
    botUsername    = "Bot1",         -- shown in dashboard bots count

    -- Discord webhook (leave "" to skip Discord)
    webhookUrl     = "",

    -- Scanning
    notifyAll      = false,
    scanInterval   = 1.5,           -- seconds between workspace scans
    minValue       = 0,             -- skip pets below this value

    -- TP
    autoTp         = false,
    tpMethodIdx    = 1,             -- 1 = Auto cascade; 2-8 = specific
    antiRollback   = true,
    arTolerance    = 8,
    arHoldFrames   = 40,
    arMaxAttempts  = 3,

    -- Server hopping
    serverHopping  = false,         -- enable to cycle through hopper pool
    hopInterval    = 120,           -- seconds to spend per server before hopping
    placeId        = 97598239454123,-- Grow a Garden 2

    -- GaG2 wild pet names to notify (lowercase)
    notifyList     = {
        "frog", "bunny", "rabbit", "cat", "dog", "bee", "butterfly",
        "snail", "bird", "owl", "fox", "deer", "squirrel", "hedgehog",
        "ladybug", "turtle", "duck", "firefly", "mantis", "axolotl",
        "golden", "rainbow", "shiny",
    },
}

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function cleanName(raw)
    return (raw:gsub("^[Ww][Ii][Ll][Dd]%s*", ""))
end

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
    if not v or v <= 0 then return "?" end
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
    for k, e in pairs(PET_EMOJI) do
        if low:find(k, 1, true) then return e end
    end
    return "🐾"
end

-- ── Scanner — GaG2 workspace folders ─────────────────────────────────────────
local SPAWN_FOLDERS = {
    "WildPetSpawns", "WildPetSpawn", "WildAnimals", "Animals",
    "WildSpawns",    "Pets",         "NPCs",         "Spawns",
    "Temporary",     "Critters",     "GardenPets",
}

local function getValue(model)
    local best = 0
    for _, lbl in ipairs(model:GetDescendants()) do
        if lbl:IsA("TextLabel") then
            local t, low = lbl.Text, lbl.Text:lower()
            if t:find("[¢%$]") or low:find("sheckle") or t:match("%d%s?[KkMmBbTt]%f[%A]") then
                local v = parseValue(t)
                if v > best then best = v end
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
                        rawName  = child.Name,
                        name     = cleanName(child.Name),
                        instance = child,
                        cf       = part.CFrame,
                        pos      = part.Position,
                        value    = getValue(child),
                        time     = getTimeLabel(child),
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

-- ── TP Engine — 7 methods + smart cascade ────────────────────────────────────
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
    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    pcall(function() hrp.CFrame = dest end)
    RunService.Heartbeat:Wait()
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function _move_glide(hrp, dest)
    local start = hrp.CFrame
    for i = 1, 20 do
        if not hrp.Parent then break end
        local t = i / 20; t = t*t*(3 - 2*t)
        pcall(function() hrp.CFrame = start:Lerp(dest, t) end)
        hrp.AssemblyLinearVelocity = Vector3.zero
        RunService.Heartbeat:Wait()
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function _move_velocity(hrp, dest)
    local speed, done, conn = 400, false, nil
    conn = RunService.Heartbeat:Connect(function()
        if not hrp or not hrp.Parent or done then if conn then conn:Disconnect() end; return end
        local diff = dest.Position - hrp.Position
        local mag  = diff.Magnitude
        if mag < 3 then
            done = true; conn:Disconnect()
            pcall(function() hrp.CFrame = dest end)
            hrp.AssemblyLinearVelocity = Vector3.zero; return
        end
        hrp.AssemblyLinearVelocity = diff.Unit * math.min(speed, mag * 10)
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < 6 do task.wait(0.04) end
    if conn then pcall(function() conn:Disconnect() end) end
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function _move_hybrid(hrp, dest)
    local far, done, conn = (dest.Position - hrp.Position).Magnitude > 40, false, nil
    if far then
        conn = RunService.Heartbeat:Connect(function()
            if not hrp or not hrp.Parent or done then if conn then conn:Disconnect() end; return end
            local diff = dest.Position - hrp.Position
            if diff.Magnitude < 12 then done = true; conn:Disconnect(); return end
            hrp.AssemblyLinearVelocity = diff.Unit * math.min(380, diff.Magnitude * 9)
        end)
        local t0 = os.clock()
        while not done and os.clock() - t0 < 5 do task.wait(0.04) end
        if conn then pcall(function() conn:Disconnect() end) end
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    pcall(function() hrp.CFrame = dest end)
    hrp.AssemblyLinearVelocity = Vector3.zero
    RunService.Heartbeat:Wait()
end

local function _move_align(hrp, dest)
    local att0 = Instance.new("Attachment"); att0.Parent = hrp
    local att1 = Instance.new("Attachment"); att1.WorldPosition = dest.Position; att1.Parent = Workspace.Terrain
    local ap = Instance.new("AlignPosition")
    ap.Mode = Enum.PositionAlignmentMode.OneAttachment
    ap.Attachment0 = att0; ap.MaxForce = 1e6; ap.MaxVelocity = 400; ap.Responsiveness = 200
    ap.Position = dest.Position; ap.Parent = hrp
    local t0 = os.clock()
    while os.clock() - t0 < 4 do
        if not hrp or not hrp.Parent then break end
        if (hrp.Position - dest.Position).Magnitude < 5 then break end
        task.wait(0.05)
    end
    pcall(function() ap:Destroy() end); pcall(function() att0:Destroy() end); pcall(function() att1:Destroy() end)
    pcall(function() hrp.CFrame = dest end)
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function _move_bodyvel(hrp, dest)
    local bv = Instance.new("BodyVelocity")
    bv.MaxForce = Vector3.new(1e6, 1e6, 1e6); bv.P = 1e4; bv.Parent = hrp
    local done, conn = false, nil
    conn = RunService.Heartbeat:Connect(function()
        if not hrp or not hrp.Parent or done then if conn then conn:Disconnect() end; return end
        local diff = dest.Position - hrp.Position
        if diff.Magnitude < 4 then
            done = true; conn:Disconnect()
            pcall(function() bv:Destroy() end)
            pcall(function() hrp.CFrame = dest end)
            hrp.AssemblyLinearVelocity = Vector3.zero; return
        end
        bv.Velocity = diff.Unit * math.min(360, diff.Magnitude * 8)
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < 6 do task.wait(0.05) end
    if conn then pcall(function() conn:Disconnect() end) end
    pcall(function() bv:Destroy() end)
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function _move_tween(hrp, dest)
    local tw = TweenService:Create(hrp, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = dest })
    tw:Play(); tw.Completed:Wait()
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local MOVE_FNS = {
    cframe=_move_cframe, glide=_move_glide, velocity=_move_velocity,
    hybrid=_move_hybrid, align=_move_align, bodyvel=_move_bodyvel, tween=_move_tween,
}
local AUTO_ORDER = { "cframe", "hybrid", "velocity", "glide", "bodyvel", "align", "tween" }

local function holdPosition(hrp, dest, TOL, frames)
    local held = 0
    for _ = 1, frames do
        local ch = LocalPlayer.Character
        hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then break end
        if (hrp.Position - dest.Position).Magnitude > TOL then
            pcall(function() hrp.CFrame = dest end)
            hrp.AssemblyLinearVelocity  = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        else held = held + 1 end
        RunService.Heartbeat:Wait()
    end
    return held
end

local function tpTo(targetCF, onStatus)
    local function stat(t) if onStatus then onStatus(t) end end
    local ch  = LocalPlayer.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hrp or not hrp.Parent then return false end
    local dest   = targetCF * CFrame.new(0, 3, 0)
    local TOL    = CFG.arTolerance
    local thresh = math.floor(CFG.arHoldFrames * 0.4)
    local methodId = TP_METHODS[CFG.tpMethodIdx].id
    local attempts = {}
    if methodId == "auto" then
        for _, id in ipairs(AUTO_ORDER) do attempts[#attempts+1] = id end
    else
        attempts[#attempts+1] = methodId
        for _, id in ipairs(AUTO_ORDER) do if id ~= methodId then attempts[#attempts+1] = id end end
    end
    for pass = 1, CFG.arMaxAttempts do
        ch  = LocalPlayer.Character
        hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then return false end
        local methodToUse = attempts[((pass - 1) % #attempts) + 1]
        stat("Attempt " .. pass .. " — " .. methodToUse)
        local moveFn = MOVE_FNS[methodToUse]
        if moveFn then pcall(moveFn, hrp, dest) end
        ch  = LocalPlayer.Character
        hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp or not hrp.Parent then return false end
        if not CFG.antiRollback then
            if (hrp.Position - dest.Position).Magnitude <= TOL then return true end
        else
            local held = holdPosition(hrp, dest, TOL, CFG.arHoldFrames)
            ch  = LocalPlayer.Character; hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            local finalD = (hrp and hrp.Parent) and (hrp.Position - dest.Position).Magnitude or math.huge
            if finalD <= TOL and held >= thresh then return true end
        end
        task.wait(0.08)
    end
    return false
end

-- ── HTTP ──────────────────────────────────────────────────────────────────────
local _httpReq = (syn and syn.request)
    or (http and http.request)
    or (rawget(_G, "request"))
    or (fluxus and fluxus.request)

local function sendWebhook(pet)
    if CFG.webhookUrl == "" or not _httpReq then return false end
    local pos    = pet.pos or Vector3.zero
    local coords = string.format("%.0f, %.0f, %.0f", pos.X, pos.Y, pos.Z)
    local jobId  = (game.JobId ~= "" and game.JobId) or "Studio"
    local plrs   = #Players:GetPlayers()
    local stamp  = ""; pcall(function() stamp = DateTime.now():ToIsoDate() end)
    local join   = string.format('game:GetService("TeleportService"):TeleportToPlaceInstance(%d, "%s")', game.PlaceId, jobId)
    local body   = HttpService:JSONEncode({
        username   = "GaG2 Notifier",
        avatar_url = "https://cdn.discordapp.com/embed/avatars/0.png",
        embeds = {{
            title       = petEmoji(pet.name) .. "  " .. pet.name,
            description = "**Wild pet spotted in Grow a Garden 2!**",
            color       = 0xA855F7,
            fields = {
                { name = "💰 Value",     value = "$" .. formatValue(pet.value),         inline = true  },
                { name = "⏱️ Time",      value = pet.time or "?",                       inline = true  },
                { name = "👥 Players",   value = plrs .. "/" .. Players.MaxPlayers,     inline = true  },
                { name = "📍 Position",  value = "`" .. coords .. "`",                  inline = false },
                { name = "🆔 Job ID",    value = "`" .. jobId .. "`",                   inline = false },
                { name = "🔗 Join",      value = "```lua\n" .. join .. "\n```",          inline = false },
            },
            footer    = { text = "GaG2 Hopper • Place " .. tostring(game.PlaceId) },
            timestamp = stamp ~= "" and stamp or nil,
        }},
    })
    local ok = pcall(function()
        _httpReq({ Url = CFG.webhookUrl, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" }, Body = body })
    end)
    return ok
end

local function sendToApi(pet)
    if CFG.apiBase == "" or not _httpReq then return false end
    local pos = pet.pos or Vector3.zero
    local payload = {
        jobId     = game.JobId,
        placeId   = game.PlaceId,
        pet       = { name = pet.name, value = pet.value, time = pet.time,
                      pos = { X = pos.X, Y = pos.Y, Z = pos.Z } },
        players   = #Players:GetPlayers(),
        maxPlayers= Players.MaxPlayers,
        timestamp = os.time(),
    }
    local ok = pcall(function()
        _httpReq({
            Url = CFG.apiBase .. "/notify",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json", ["username"] = CFG.botUsername },
            Body = HttpService:JSONEncode(payload),
        })
    end)
    return ok
end

local function getNextServer()
    if CFG.apiBase == "" or not _httpReq then return nil end
    local nextJobId = nil
    -- Try /remove first (reports current server as done + gets replacement)
    if game.JobId ~= "" then
        pcall(function()
            local res = _httpReq({
                Url = CFG.apiBase .. "/remove",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json", ["username"] = CFG.botUsername },
                Body = HttpService:JSONEncode({ jobid = game.JobId }),
            })
            if res and res.Body then
                local ok, d = pcall(function() return HttpService:JSONDecode(res.Body) end)
                if ok and d and d.new_jobid then nextJobId = d.new_jobid end
            end
        end)
    end
    -- Fallback: get a fresh server from /server
    if not nextJobId then
        pcall(function()
            local res = _httpReq({
                Url = CFG.apiBase .. "/server",
                Method = "GET",
                Headers = { ["username"] = CFG.botUsername },
            })
            if res and res.Body then
                local jid = res.Body:match("^%s*(.-)%s*$")
                if jid and jid ~= "" then nextJobId = jid end
            end
        end)
    end
    return nextJobId
end

-- ── UI ───────────────────────────────────────────────────────────────────────
do
    local ParentUI
    local ok = pcall(function() ParentUI = game:GetService("CoreGui") end)
    if not ok or not ParentUI then ParentUI = LocalPlayer:WaitForChild("PlayerGui") end
    if ParentUI:FindFirstChild("GaG2_Scanner_Gui") then ParentUI.GaG2_Scanner_Gui:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name = "GaG2_Scanner_Gui"; sg.ResetOnSpawn = false; sg.IgnoreGuiInset = true
    sg.DisplayOrder = 999998; sg.Parent = ParentUI

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
        knob    = Color3.fromRGB(220, 200, 255),
    }
    local W = 295

    local card = Instance.new("Frame", sg)
    card.Size = UDim2.new(0, W, 0, 0)
    card.Position = UDim2.new(0.5, W/2 + 12, 0.28, 0)
    card.BackgroundColor3 = C.card; card.BorderSizePixel = 0
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 14)
    local cs = Instance.new("UIStroke", card); cs.Thickness = 1; cs.Color = C.accent; cs.Transparency = 0.45

    local HDR, FTR_H, PAD = 42, 20, 8

    local hdr = Instance.new("Frame", card)
    hdr.Size = UDim2.new(1, 0, 0, HDR); hdr.BackgroundColor3 = C.surface; hdr.BorderSizePixel = 0
    Instance.new("UICorner", hdr).CornerRadius = UDim.new(0, 14)
    local hsq = Instance.new("Frame", hdr)
    hsq.Size = UDim2.new(1, 0, 0, 14); hsq.Position = UDim2.new(0, 0, 1, -14)
    hsq.BackgroundColor3 = C.surface; hsq.BorderSizePixel = 0

    local titleLbl = Instance.new("TextLabel", hdr)
    titleLbl.Size = UDim2.new(1, 0, 1, 0); titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🌱  GaG2 SCANNER + HOP"; titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 13; titleLbl.TextColor3 = C.accent; titleLbl.TextXAlignment = Enum.TextXAlignment.Center

    local sentBadge = Instance.new("TextLabel", hdr)
    sentBadge.Size = UDim2.new(0, 48, 0, 18); sentBadge.Position = UDim2.new(0, 8, 0.5, -9)
    sentBadge.BackgroundColor3 = C.surfHi; sentBadge.BorderSizePixel = 0
    sentBadge.Text = "0 sent"; sentBadge.Font = Enum.Font.GothamBold; sentBadge.TextSize = 9
    sentBadge.TextColor3 = C.accent2
    Instance.new("UICorner", sentBadge).CornerRadius = UDim.new(0, 5)

    local minBtn = Instance.new("TextButton", hdr)
    minBtn.Size = UDim2.new(0, 26, 0, 26); minBtn.Position = UDim2.new(1, -33, 0.5, -13)
    minBtn.BackgroundColor3 = C.surfHi; minBtn.BorderSizePixel = 0
    minBtn.Text = "−"; minBtn.Font = Enum.Font.GothamBold; minBtn.TextSize = 15
    minBtn.TextColor3 = C.txtSub; minBtn.AutoButtonColor = false
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 7)

    local body = Instance.new("Frame", card)
    body.BackgroundTransparency = 1; body.BorderSizePixel = 0
    body.Position = UDim2.new(0, PAD, 0, HDR + PAD); body.Size = UDim2.new(1, -PAD*2, 0, 0)
    local bodyLayout = Instance.new("UIListLayout", body)
    bodyLayout.Padding = UDim.new(0, 5); bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    local ftrLbl = Instance.new("TextLabel", card)
    ftrLbl.Size = UDim2.new(1, 0, 0, FTR_H); ftrLbl.BackgroundTransparency = 1
    ftrLbl.Text = "GaG2 Hopper"; ftrLbl.Font = Enum.Font.GothamBold; ftrLbl.TextSize = 9
    ftrLbl.TextColor3 = C.txtMute; ftrLbl.TextXAlignment = Enum.TextXAlignment.Center

    local minimized = false
    local function fit()
        if minimized then return end
        local h = HDR + PAD + bodyLayout.AbsoluteContentSize.Y + PAD + FTR_H
        card.Size = UDim2.new(0, W, 0, h)
        body.Size = UDim2.new(1, -PAD*2, 0, bodyLayout.AbsoluteContentSize.Y)
        ftrLbl.Position = UDim2.new(0, 0, 1, -FTR_H)
    end
    local function setMin(m)
        minimized = m; body.Visible = not m
        if m then card.Size = UDim2.new(0, W, 0, HDR + FTR_H); ftrLbl.Position = UDim2.new(0, 0, 1, -FTR_H); minBtn.Text = "+"
        else fit(); minBtn.Text = "−" end
    end
    minBtn.MouseButton1Click:Connect(function() setMin(not minimized) end)

    local function mkRow(order, h)
        local f = Instance.new("Frame", body)
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
    local function mkLabel(parent, txt, xOff, col)
        local l = Instance.new("TextLabel", parent)
        l.Size = UDim2.new(1, -60, 1, 0); l.Position = UDim2.new(0, xOff or 10, 0, 0)
        l.BackgroundTransparency = 1; l.Text = txt
        l.Font = Enum.Font.GothamMedium; l.TextSize = 10; l.TextColor3 = col or C.txtSub
        l.TextXAlignment = Enum.TextXAlignment.Left
        return l
    end

    -- Status (LO=1)
    local stRow = mkRow(1, 26)
    local stDot = Instance.new("Frame", stRow)
    stDot.Size = UDim2.new(0, 7, 0, 7); stDot.Position = UDim2.new(0, 10, 0.5, -3.5)
    stDot.BackgroundColor3 = C.txtMute; stDot.BorderSizePixel = 0
    Instance.new("UICorner", stDot).CornerRadius = UDim.new(1, 0)
    local stLbl = Instance.new("TextLabel", stRow)
    stLbl.Size = UDim2.new(1, -24, 1, 0); stLbl.Position = UDim2.new(0, 22, 0, 0)
    stLbl.BackgroundTransparency = 1; stLbl.Text = "Idle"
    stLbl.Font = Enum.Font.GothamMedium; stLbl.TextSize = 10; stLbl.TextColor3 = C.txtSub
    stLbl.TextXAlignment = Enum.TextXAlignment.Left; stLbl.TextTruncate = Enum.TextTruncate.AtEnd
    local sentCount = 0
    local function setStatus(t, c)
        stLbl.Text = t; stLbl.TextColor3 = c or C.txtSub; stDot.BackgroundColor3 = c or C.txtMute
    end
    local function bumpSent()
        sentCount = sentCount + 1; sentBadge.Text = tostring(sentCount) .. " sent"
    end

    -- API URL (LO=2)
    local aRow = mkRow(2, 32)
    local aBox = Instance.new("TextBox", aRow)
    aBox.Size = UDim2.new(1, -16, 1, -8); aBox.Position = UDim2.new(0, 7, 0, 4)
    aBox.BackgroundColor3 = C.surfHi; aBox.BorderSizePixel = 0
    aBox.Text = CFG.apiBase; aBox.PlaceholderText = "https://your-app.railway.app"
    aBox.Font = Enum.Font.Gotham; aBox.TextSize = 9; aBox.TextColor3 = C.txt
    aBox.ClearTextOnFocus = false; aBox.TextXAlignment = Enum.TextXAlignment.Left
    aBox.TextTruncate = Enum.TextTruncate.AtEnd
    Instance.new("UICorner", aBox).CornerRadius = UDim.new(0, 6)
    Instance.new("UIPadding", aBox).PaddingLeft = UDim.new(0, 7)
    aBox.FocusLost:Connect(function() CFG.apiBase = aBox.Text end)

    -- Webhook URL (LO=3)
    local wRow = mkRow(3, 32)
    local wBox = Instance.new("TextBox", wRow)
    wBox.Size = UDim2.new(1, -60, 1, -8); wBox.Position = UDim2.new(0, 7, 0, 4)
    wBox.BackgroundColor3 = C.surfHi; wBox.BorderSizePixel = 0
    wBox.Text = CFG.webhookUrl; wBox.PlaceholderText = "Discord webhook URL…"
    wBox.Font = Enum.Font.Gotham; wBox.TextSize = 9; wBox.TextColor3 = C.txt
    wBox.ClearTextOnFocus = false; wBox.TextXAlignment = Enum.TextXAlignment.Left
    wBox.TextTruncate = Enum.TextTruncate.AtEnd
    Instance.new("UICorner", wBox).CornerRadius = UDim.new(0, 6)
    Instance.new("UIPadding", wBox).PaddingLeft = UDim.new(0, 7)
    wBox.FocusLost:Connect(function() CFG.webhookUrl = wBox.Text end)
    local wTest = Instance.new("TextButton", wRow)
    wTest.Size = UDim2.new(0, 44, 1, -8); wTest.Position = UDim2.new(1, -50, 0, 4)
    wTest.BackgroundColor3 = C.accent; wTest.BorderSizePixel = 0; wTest.Text = "Test"
    wTest.Font = Enum.Font.GothamBold; wTest.TextSize = 10; wTest.TextColor3 = C.txt; wTest.AutoButtonColor = false
    Instance.new("UICorner", wTest).CornerRadius = UDim.new(0, 6)
    wTest.MouseButton1Click:Connect(function()
        CFG.webhookUrl = wBox.Text
        task.spawn(function()
            if CFG.webhookUrl == "" then setStatus("Set webhook URL first", C.red); return end
            if not _httpReq then setStatus("No HTTP in executor", C.red); return end
            local sent = pcall(function()
                _httpReq({ Url = CFG.webhookUrl, Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode({ username = "GaG2 Notifier", content = "✅ Connected!" }) })
            end)
            setStatus(sent and "Webhook OK ✔" or "Webhook failed", sent and C.green or C.red)
        end)
    end)

    -- TP Method (LO=4)
    local mRow = mkRow(4, 32)
    local mLbl = Instance.new("TextLabel", mRow)
    mLbl.Size = UDim2.new(0, 72, 1, 0); mLbl.Position = UDim2.new(0, 10, 0, 0)
    mLbl.BackgroundTransparency = 1; mLbl.Text = "TP Method"
    mLbl.Font = Enum.Font.GothamBold; mLbl.TextSize = 10; mLbl.TextColor3 = C.txtMute
    mLbl.TextXAlignment = Enum.TextXAlignment.Left
    local mPrev = Instance.new("TextButton", mRow)
    mPrev.Size = UDim2.new(0, 22, 0, 22); mPrev.Position = UDim2.new(0, 84, 0.5, -11)
    mPrev.BackgroundColor3 = C.surfHi; mPrev.BorderSizePixel = 0; mPrev.Text = "◄"
    mPrev.Font = Enum.Font.GothamBold; mPrev.TextSize = 10; mPrev.TextColor3 = C.accent; mPrev.AutoButtonColor = false
    Instance.new("UICorner", mPrev).CornerRadius = UDim.new(0, 6)
    local mVal = Instance.new("TextLabel", mRow)
    mVal.Size = UDim2.new(0, 106, 1, 0); mVal.Position = UDim2.new(0, 108, 0, 0)
    mVal.BackgroundTransparency = 1; mVal.Text = TP_METHODS[CFG.tpMethodIdx].name
    mVal.Font = Enum.Font.GothamMedium; mVal.TextSize = 10; mVal.TextColor3 = C.accent2
    mVal.TextXAlignment = Enum.TextXAlignment.Center
    local mNext = Instance.new("TextButton", mRow)
    mNext.Size = UDim2.new(0, 22, 0, 22); mNext.Position = UDim2.new(1, -30, 0.5, -11)
    mNext.BackgroundColor3 = C.surfHi; mNext.BorderSizePixel = 0; mNext.Text = "►"
    mNext.Font = Enum.Font.GothamBold; mNext.TextSize = 10; mNext.TextColor3 = C.accent; mNext.AutoButtonColor = false
    Instance.new("UICorner", mNext).CornerRadius = UDim.new(0, 6)
    mPrev.MouseButton1Click:Connect(function()
        CFG.tpMethodIdx = ((CFG.tpMethodIdx - 2) % #TP_METHODS) + 1; mVal.Text = TP_METHODS[CFG.tpMethodIdx].name
    end)
    mNext.MouseButton1Click:Connect(function()
        CFG.tpMethodIdx = (CFG.tpMethodIdx % #TP_METHODS) + 1; mVal.Text = TP_METHODS[CFG.tpMethodIdx].name
    end)

    -- Anti-Rollback (LO=5)
    local arRow = mkRow(5, 28); mkLabel(arRow, "Anti-Rollback", 10, C.txtSub)
    local arSw, _, arToggle = mkSwitch(arRow, -48, CFG.antiRollback)
    arSw.MouseButton1Click:Connect(function() CFG.antiRollback = not CFG.antiRollback; arToggle(CFG.antiRollback) end)

    -- Auto-TP (LO=6)
    local atRow = mkRow(6, 28); mkLabel(atRow, "Auto-TP on detect", 10, C.txtSub)
    local atSw, _, atToggle = mkSwitch(atRow, -48, CFG.autoTp)
    atSw.MouseButton1Click:Connect(function() CFG.autoTp = not CFG.autoTp; atToggle(CFG.autoTp) end)

    -- Notify All (LO=7)
    local nRow = mkRow(7, 28); mkLabel(nRow, "Notify all pets", 10, C.txtSub)
    local nSw, _, nToggle = mkSwitch(nRow, -48, CFG.notifyAll)
    nSw.MouseButton1Click:Connect(function() CFG.notifyAll = not CFG.notifyAll; nToggle(CFG.notifyAll) end)

    -- Server Hopping (LO=8)
    local hopRow = mkRow(8, 28); mkLabel(hopRow, "Server Hopping", 10, C.txtSub)
    local hopSw, _, hopToggle = mkSwitch(hopRow, -48, CFG.serverHopping)
    hopSw.MouseButton1Click:Connect(function() CFG.serverHopping = not CFG.serverHopping; hopToggle(CFG.serverHopping) end)

    -- Buttons (LO=9)
    local btnOuter = Instance.new("Frame", body)
    btnOuter.Size = UDim2.new(1, 0, 0, 30); btnOuter.BackgroundTransparency = 1; btnOuter.LayoutOrder = 9
    local btnL = Instance.new("UIListLayout", btnOuter)
    btnL.FillDirection = Enum.FillDirection.Horizontal; btnL.Padding = UDim.new(0, 5)
    btnL.HorizontalAlignment = Enum.HorizontalAlignment.Center; btnL.VerticalAlignment = Enum.VerticalAlignment.Center

    local function mkBtn2(txt, bg)
        local b = Instance.new("TextButton", btnOuter)
        b.Size = UDim2.new(0.5, -4, 1, 0); b.BackgroundColor3 = bg; b.BorderSizePixel = 0
        b.AutoButtonColor = false; b.Text = txt
        b.Font = Enum.Font.GothamBold; b.TextSize = 11; b.TextColor3 = C.txt
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
        b.MouseEnter:Connect(function() b.BackgroundColor3 = bg:Lerp(Color3.new(1,1,1), 0.12) end)
        b.MouseLeave:Connect(function() b.BackgroundColor3 = bg end)
        return b
    end
    local tpLastBtn = mkBtn2("⚡ TP Last", C.accent)
    local scanBtn   = mkBtn2("⟳ Scan",    C.surfHi)

    -- Fit + Drag
    bodyLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
    task.defer(fit)
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

    -- Logic
    local lastPet = nil
    local tpBusy  = false
    local _sentOnce = {}

    local function petKey(p) return p.name .. "|" .. tostring(math.round(p.pos.X)) .. "|" .. tostring(math.round(p.pos.Z)) end
    local function isTracked(name)
        if CFG.notifyAll then return true end
        local low = name:lower()
        for _, pat in ipairs(CFG.notifyList) do if low:find(pat, 1, true) then return true end end
        return false
    end

    local function doTpTo(pet, label)
        if tpBusy then return end
        tpBusy = true
        local lbl = label or "TP"
        setStatus(lbl .. " → " .. pet.name .. "…", C.yellow)
        task.spawn(function()
            if pet.instance and pet.instance.Parent then
                local part = pet.instance:IsA("BasePart") and pet.instance
                    or pet.instance:FindFirstChildWhichIsA("BasePart")
                if part then pet.cf = part.CFrame end
            end
            local ok = tpTo(pet.cf, function(s) setStatus(s, C.txtSub) end)
            setStatus(ok and ("✔ Arrived: " .. pet.name) or ("✘ TP failed: " .. pet.name), ok and C.green or C.red)
            tpBusy = false
        end)
    end

    local function doScan()
        local pets = scanPets()
        local notified = 0
        for _, p in ipairs(pets) do
            local key = petKey(p)
            if not _sentOnce[key] and isTracked(p.name) and (p.value or 0) >= CFG.minValue then
                _sentOnce[key] = true
                notified = notified + 1
                bumpSent()
                lastPet = p
                task.spawn(function()
                    local sent = sendWebhook(p)
                    if not sent then _sentOnce[key] = nil end
                end)
                task.spawn(function() sendToApi(p) end)
                if CFG.autoTp and not tpBusy then doTpTo(p, "Auto-TP") end
            end
        end
        if #pets == 0 then setStatus("No pets found", C.txtMute)
        elseif notified > 0 then setStatus("Sent " .. notified .. " notification(s)!", C.green)
        else setStatus(#pets .. " pet(s) — all already notified", C.accent2) end
        fit()
    end

    scanBtn.MouseButton1Click:Connect(function() setStatus("Scanning…", C.yellow); task.spawn(doScan) end)
    tpLastBtn.MouseButton1Click:Connect(function()
        if not lastPet then setStatus("No pet detected yet", C.red); return end
        doTpTo(lastPet, "TP Last")
    end)

    -- Main scan loop
    task.spawn(function()
        while sg.Parent do pcall(doScan); task.wait(CFG.scanInterval) end
    end)
    task.delay(0.5, function() pcall(doScan) end)

    -- Server hopper loop
    task.spawn(function()
        task.wait(CFG.hopInterval)
        while sg.Parent do
            if CFG.serverHopping and CFG.apiBase ~= "" then
                setStatus("🔀 Hopping servers…", C.yellow)
                local nextJobId = getNextServer()
                if nextJobId and nextJobId ~= "" and nextJobId ~= game.JobId then
                    task.wait(1.5)
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(CFG.placeId, nextJobId)
                    end)
                else
                    setStatus("Hop: no server available, retrying…", C.txtMute)
                end
            end
            task.wait(CFG.hopInterval)
        end
    end)
end
