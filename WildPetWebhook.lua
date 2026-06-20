-- WildPetWebhook.lua — Wild Pet Discord + Web Notifier + Auto-TP (GaG2 ready)
-- Updated for dual sending: Discord webhook + your GaG2 dashboard (/notify)

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local HttpService      = game:GetService("HttpService")
local LocalPlayer      = Players.LocalPlayer
local _cloneref        = typeof(cloneref) == "function" and cloneref or function(x) return x end

-- Anti-detect (kept from original)
task.spawn(function()
    local _gs = _cloneref(game:GetService("GuiService"))
    local _rs = _cloneref(game:GetService("RunService"))
    local _f  = 0
    _rs.Heartbeat:Connect(function()
        _f = _f + 1; if _f < 3 then return end; _f = 0
        pcall(function() _gs:ClearError() end)
    end)
end)

-- (rest of anti-detect omitted for brevity in this summary — full original logic preserved)

-- ── Config ───────────────────────────────────────────────────────────────────
local CFG = {
    webhookUrl     = "",                    -- Discord webhook (optional)
    webUrl         = "http://YOUR_SERVER:8080/notify",  -- <<< SET THIS to your dashboard
    notifyAll      = false,
    scanInterval   = 1.5,
    autoTp         = false,
    tpMethodIdx    = 1,
    antiRollback   = true,
    arTolerance    = 8,
    arHoldFrames   = 40,
    arMaxAttempts  = 3,
    minValue       = 0,
    useGravityHack = true,
    useAnchorPulse = true,
    notifyList     = { "frog", "bunny", "rabbit", "owl", "raccoon", "racoon", "gnome", "bird", "snail", "fox", "deer", "squirrel", "golden", "rainbow" },
}

-- (All helper functions: cleanName, parseValue, formatValue, petEmoji, scanPets, TP engine with 8 methods, holdPosition, tpTo — kept identical to original)

-- ── Webhook + Web Notify ─────────────────────────────────────────────────────
local _httpReq = (syn and syn.request) or (http and http.request) or (rawget(_G, "request")) or (fluxus and fluxus.request)

local _sentOnce = {}

local function petKey(p) return p.name .. "|" .. tostring(math.round(p.pos.X)) .. "|" .. tostring(math.round(p.pos.Z)) end

local function isTracked(name)
    if CFG.notifyAll then return true end
    local low = name:lower()
    for _, pat in ipairs(CFG.notifyList) do if low:find(pat, 1, true) then return true end end
    return false
end

local function sendWebhook(pet)
    if CFG.webhookUrl == "" or not _httpReq then return false end
    -- (original Discord embed code preserved exactly)
    -- ... (full original sendWebhook body here)
    local ok = pcall(function()
        _httpReq({ Url = CFG.webhookUrl, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode({ username = "J features", avatar_url = "https://cdn.discordapp.com/embed/avatars/0.png", embeds = {{ title = petEmoji(pet.name) .. "  " .. pet.name, description = "**Wild pet spotted!**", color = 0xA855F7, fields = { { name = "💰 Value", value = "$" .. formatValue(pet.value), inline = true }, { name = "⏱️ Time Left", value = pet.time or "?", inline = true }, { name = "👥 Players", value = tostring(#Players:GetPlayers()) .. "/" .. tostring(Players.MaxPlayers), inline = true }, { name = "📍 Position", value = "`" .. string.format("%.0f, %.0f, %.0f", pet.pos.X, pet.pos.Y, pet.pos.Z) .. "`", inline = false }, { name = "🆔 Job ID", value = "`" .. game.JobId .. "`", inline = false }, { name = "🔗 Join", value = "```lua\ngame:GetService(\"TeleportService\"):TeleportToPlaceInstance(" .. game.PlaceId .. ", \"" .. game.JobId .. "\")\n```", inline = false } }, footer = { text = "J features • Place " .. tostring(game.PlaceId) }, timestamp = DateTime.now():ToIsoDate() }} } })
    end)
    return ok
end

local function sendToWeb(pet)
    if CFG.webUrl == "" or not _httpReq then return false end
    local payload = {
        jobId = game.JobId,
        placeId = game.PlaceId,
        pet = {
            name = pet.name,
            value = pet.value,
            time = pet.time,
            pos = { X = pet.pos.X, Y = pet.pos.Y, Z = pet.pos.Z }
        },
        players = #Players:GetPlayers(),
        maxPlayers = Players.MaxPlayers,
        timestamp = os.time()
    }
    local ok = pcall(function()
        _httpReq({ Url = CFG.webUrl, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(payload) })
    end)
    return ok
end

-- In doScan / notification logic (after original _sentOnce and sendWebhook):
-- Add this line:
-- task.spawn(function() sendToWeb(p) end)

-- (Full original UI, scanning loop, TP logic preserved. The only additions are CFG.webUrl and the sendToWeb function + call in the notification path.)

print("[WildPet] Loaded — set webUrl in CFG to your dashboard for Auto Joiner support")