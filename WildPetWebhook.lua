-- WildPetWebhook.lua — GaG2 Wild Pet Scanner + Server Hopper
-- Per server: scans ONCE, reports findings to your hopper API & Discord, then hops to the next server. Repeat.
-- No teleport-to-pet logic — it only scans and hops.

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local HttpService      = game:GetService("HttpService")
local TeleportService  = game:GetService("TeleportService")
local Lighting         = game:GetService("Lighting")
local SoundService     = game:GetService("SoundService")
local LocalPlayer      = Players.LocalPlayer
local _cloneref        = typeof(cloneref) == "function" and cloneref or function(x) return x end

-- ── VPS / Multi-bot Performance Optimizations ────────────────────────────────
-- FPS cap: 1 FPS is enough for a headless scanner; saves massive CPU per instance.
-- Tries Delta, Synapse, Fluxus, then generic fallback.
pcall(function() setfpscap(1) end)
pcall(function() if syn and syn.set_fps_cap then syn.set_fps_cap(1) end end)
pcall(function() if fluxus and fluxus.set_fps_cap then fluxus.set_fps_cap(1) end end)
pcall(function()
    -- Delta executor flag: disable renderer outright
    if getgenv and getgenv().delta and getgenv().delta.setfpscap then
        getgenv().delta.setfpscap(1)
    end
end)

-- Disable 3D rendering entirely (supported by some executors: Delta, Synapse X)
pcall(function() RunService:Set3dRenderingEnabled(false) end)
pcall(function() if syn and syn.set_rendering_enabled then syn.set_rendering_enabled(false) end end)

-- Minimum graphics quality
pcall(function()
    local s = settings()
    s.Rendering.QualityLevel      = Enum.QualityLevel.Level01
    s.Rendering.EagerBulkExecution = true
    s.Rendering.MaxDecals          = 0
    s.Rendering.MaxParticles       = 0
end)

-- Kill shadows and fog
pcall(function()
    Lighting.GlobalShadows    = false
    Lighting.FogEnd           = 9e9
    Lighting.Brightness       = 0
    Lighting.EnvironmentDiffuseScale  = 0
    Lighting.EnvironmentSpecularScale = 0
end)

-- Mute SoundService globally
pcall(function()
    SoundService.AmbientReverb = Enum.ReverbType.NoReverb
    SoundService.DistanceFactor = 0
end)

-- Disable particles, fire, smoke, sparkles, beams, and mute all sounds in the workspace.
-- Runs in background so it doesn't block the settle timer.
task.spawn(function()
    for _, obj in ipairs(game:GetDescendants()) do
        local t = obj.ClassName
        if t == "Sound" then
            pcall(function() obj.Volume = 0; obj:Stop() end)
        elseif t == "ParticleEmitter" or t == "Smoke" or t == "Fire"
            or t == "Sparkles" or t == "Beam" or t == "Trail" then
            pcall(function() obj.Enabled = false end)
        elseif t == "SpecialMesh" or t == "SelectionBox" then
            pcall(function() obj.Transparency = 1 end)
        end
    end
    -- Also mute anything that spawns later
    game.DescendantAdded:Connect(function(obj)
        local t = obj.ClassName
        if t == "Sound" then
            pcall(function() obj.Volume = 0; obj:Stop() end)
        elseif t == "ParticleEmitter" or t == "Smoke" or t == "Fire"
            or t == "Sparkles" or t == "Beam" or t == "Trail" then
            pcall(function() obj.Enabled = false end)
        end
    end)
end)

-- Stop character animations and disable auto-rotate / auto-jump
pcall(function()
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.AutoJumpEnabled = false
        hum.AutoRotate      = false
        hum.WalkSpeed       = 0
        hum.JumpPower       = 0
    end
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            pcall(function() track:Stop(0) end)
        end
    end
end)

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
    apiBase        = "https://gag2-production-d10c.up.railway.app",
    botUsername    = "Bot1",         -- shown in dashboard bots count

    -- Discord webhook (leave "" to skip Discord)
    webhookUrl     = "",

    -- Scanning
    notifyAll      = false,
    minValue       = 0,             -- skip pets below this value
    settleDelay    = 5,             -- seconds to wait after join before scanning (let workspace load)

    -- Server hopping (the core loop: scan once -> hop -> repeat)
    serverHopping  = true,
    placeId        = 97598239454123,-- Grow a Garden 2
    -- Raw URL used to re-run this script in the next server after a teleport.
    -- Point it at your hosted copy of this file (GitHub raw, pastebin, etc.).
    loaderUrl      = "https://raw.githubusercontent.com/Unnamedj/gag2/main/WildPetWebhook.lua",

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

-- ── HTTP ──────────────────────────────────────────────────────────────────────
local _httpReq = (syn and syn.request)
    or (http and http.request)
    or (rawget(_G, "request"))
    or (fluxus and fluxus.request)

local _queueTp = (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)
    or (rawget(_G, "queue_on_teleport"))
    or (rawget(_G, "queueonteleport"))

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

-- Asks the hopper API for the next server: reports the current one via /remove
-- (which also returns a replacement jobId) and falls back to /server.
local function getNextServer()
    if CFG.apiBase == "" or not _httpReq then return nil end
    local nextJobId = nil
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
    if not nextJobId then
        pcall(function()
            local res = _httpReq({
                Url = CFG.apiBase .. "/server",
                Method = "GET",
                Headers = { ["username"] = CFG.botUsername },
            })
            if res and res.Body then
                local jid = res.Body:match("^%s*(.-)%s*$")
                if jid and jid ~= "" and not jid:find("[<>{}]") then nextJobId = jid end
            end
        end)
    end
    return nextJobId
end

-- Queue this script to auto-run again in the next server after teleport.
local function queueReload()
    if CFG.loaderUrl == "" or not _queueTp then return end
    pcall(function()
        _queueTp('loadstring(game:HttpGet("' .. CFG.loaderUrl .. '"))()')
    end)
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
    sentBadge.Size = UDim2.new(0, 56, 0, 18); sentBadge.Position = UDim2.new(0, 8, 0.5, -9)
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
        task.spawn(function()
            if CFG.apiBase == "" then setStatus("Set API URL first", C.red); return end
            if not _httpReq then setStatus("No HTTP in executor", C.red); return end
            local good = false
            pcall(function()
                local res = _httpReq({ Url = CFG.apiBase .. "/stats", Method = "GET" })
                good = res and (res.StatusCode == 200 or res.Success)
            end)
            setStatus(good and "API connected ✔" or "API failed", good and C.green or C.red)
        end)
    end)

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

    -- Notify All (LO=4)
    local nRow = mkRow(4, 28); mkLabel(nRow, "Notify all pets", 10, C.txtSub)
    local nSw, _, nToggle = mkSwitch(nRow, -48, CFG.notifyAll)
    nSw.MouseButton1Click:Connect(function() CFG.notifyAll = not CFG.notifyAll; nToggle(CFG.notifyAll) end)

    -- Server Hopping (LO=5)
    local hopRow = mkRow(5, 28); mkLabel(hopRow, "Server Hopping", 10, C.accent2)
    local hopSw, _, hopToggle = mkSwitch(hopRow, -48, CFG.serverHopping)
    hopSw.MouseButton1Click:Connect(function() CFG.serverHopping = not CFG.serverHopping; hopToggle(CFG.serverHopping) end)

    -- Buttons (LO=6)
    local btnOuter = Instance.new("Frame", body)
    btnOuter.Size = UDim2.new(1, 0, 0, 30); btnOuter.BackgroundTransparency = 1; btnOuter.LayoutOrder = 6
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
    local scanBtn = mkBtn2("⟳ Scan",    C.surfHi)
    local hopBtn  = mkBtn2("🔀 Hop Now", C.accent)

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

    -- ── Core logic: scan once, then hop ──────────────────────────────────────
    local _sentOnce = {}
    local hopping   = false   -- guards against double-teleport

    local function petKey(p) return p.name .. "|" .. tostring(math.round(p.pos.X)) .. "|" .. tostring(math.round(p.pos.Z)) end
    local function isTracked(name)
        if CFG.notifyAll then return true end
        local low = name:lower()
        for _, pat in ipairs(CFG.notifyList) do if low:find(pat, 1, true) then return true end end
        return false
    end

    -- Scans the current server once and reports any new pets to API + Discord.
    local function doScan()
        local pets = scanPets()
        local notified = 0
        for _, p in ipairs(pets) do
            local key = petKey(p)
            if not _sentOnce[key] and isTracked(p.name) and (p.value or 0) >= CFG.minValue then
                _sentOnce[key] = true
                notified = notified + 1
                bumpSent()
                task.spawn(function()
                    local sent = sendWebhook(p)
                    if not sent then _sentOnce[key] = nil end
                end)
                task.spawn(function() sendToApi(p) end)
            end
        end
        if #pets == 0 then setStatus("No pets found", C.txtMute)
        elseif notified > 0 then setStatus("Sent " .. notified .. " notification(s)!", C.green)
        else setStatus(#pets .. " pet(s) — all already sent", C.accent2) end
        fit()
        return #pets
    end

    -- Reports current server + teleports to the next one.
    local function hopNow()
        if hopping then return end
        hopping = true
        setStatus("🔀 Finding next server…", C.yellow)
        task.spawn(function()
            local nextJobId = getNextServer()
            queueReload()  -- ensure this script re-runs in the next server
            task.wait(0.8)
            local ok = false
            if nextJobId and nextJobId ~= "" and nextJobId ~= game.JobId then
                setStatus("🔀 Hopping → " .. nextJobId:sub(1, 8) .. "…", C.yellow)
                ok = pcall(function() TeleportService:TeleportToPlaceInstance(CFG.placeId, nextJobId) end)
            end
            -- Fallback: no API server → jump to a random new server of the same place.
            if not ok then
                setStatus("🔀 Hopping → random server…", C.yellow)
                pcall(function() TeleportService:Teleport(CFG.placeId, LocalPlayer) end)
            end
            -- If teleport silently failed, allow another attempt later.
            task.wait(8)
            hopping = false
            setStatus("Hop failed — will retry", C.red)
        end)
    end

    -- Manual buttons
    scanBtn.MouseButton1Click:Connect(function() setStatus("Scanning…", C.yellow); task.spawn(doScan) end)
    hopBtn.MouseButton1Click:Connect(function() hopNow() end)

    -- Automatic per-server cycle (strictly sequential: settle → scan → hop)
    -- Hop is GUARANTEED to only fire after doScan() has fully returned.
    task.spawn(function()
        setStatus("Settling… (" .. CFG.settleDelay .. "s)", C.txtSub)
        task.wait(CFG.settleDelay)

        -- STEP 1: SCAN — blocks here until scan is 100% complete
        setStatus("Scanning…", C.yellow)
        pcall(doScan)
        -- Brief pause so any task.spawn'd HTTP requests get a chance to fire
        task.wait(1.5)

        -- STEP 2: HOP — only reached after scan is done
        if CFG.serverHopping then
            hopNow()
        else
            -- Wait here until user toggles Server Hopping on, then hop
            repeat task.wait(0.5) until not sg.Parent or CFG.serverHopping
            if sg.Parent then hopNow() end
        end
    end)
end
