-- AutoJoiner.lua — GaG2 Wild Pet Auto Joiner
-- Polls your dashboard API and auto-teleports to the best (highest value) wild pet server

if not game:IsLoaded() then game.Loaded:Wait() end

local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- CONFIG
local API_BASE = "http://YOUR_SERVER_IP_OR_DOMAIN:8080"   -- <<< CHANGE THIS
local MIN_VALUE = 250000          -- Only join if pet value >= this (0 = any)
local POLL_INTERVAL = 6           -- seconds between checks
local MAX_JOIN_ATTEMPTS = 3
local PLACE_ID = 97598239454123   -- GaG2

local _httpReq = (syn and syn.request) or (http and http.request) or (rawget(_G, "request")) or (fluxus and fluxus.request)

local lastJoinedKey = ""
local joinCount = 0

local function log(msg) print("[AutoJoiner] " .. msg) end

local function getBestPet()
    if not _httpReq then return nil end
    local ok, res = pcall(function()
        return _httpReq({
            Url = API_BASE .. "/api/best",
            Method = "GET",
            Headers = { ["User-Agent"] = "GaG2-AutoJoiner" }
        })
    end)
    if not ok or not res or not res.Body then return nil end
    local data = HttpService:JSONDecode(res.Body)
    return data and data.best or nil
end

local function shouldJoin(pet)
    if not pet or not pet.pet then return false end
    if (pet.pet.value or 0) < MIN_VALUE then return false end
    local key = pet.jobId .. "|" .. pet.pet.name
    if key == lastJoinedKey then return false end
    return true
end

local function doJoin(pet)
    if not pet or not pet.jobId then return false end
    lastJoinedKey = pet.jobId .. "|" .. (pet.pet and pet.pet.name or "?")
    joinCount = joinCount + 1
    log("Joining " .. (pet.pet and pet.pet.name or "?") .. " (Value: $" .. tostring(pet.pet and pet.pet.value or 0) .. ") → " .. pet.jobId)

    for attempt = 1, MAX_JOIN_ATTEMPTS do
        local success = pcall(function()
            TeleportService:TeleportToPlaceInstance(PLACE_ID, pet.jobId)
        end)
        if success then
            log("Teleport initiated (attempt " .. attempt .. ")")
            return true
        end
        task.wait(1.5)
    end
    log("All teleport attempts failed")
    return false
end

-- Main loop
task.spawn(function()
    log("AutoJoiner started. Polling every " .. POLL_INTERVAL .. "s | Min value: $" .. MIN_VALUE)
    while true do
        local best = getBestPet()
        if best and shouldJoin(best) then
            doJoin(best)
        end
        task.wait(POLL_INTERVAL)
    end
end)

-- Optional: simple UI status (if executor supports)
if game:GetService("CoreGui") then
    -- You can add a small ScreenGui here if desired
end

print("[AutoJoiner] Loaded — edit API_BASE and run in executor")