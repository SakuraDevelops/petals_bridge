---@diagnostic disable: lowercase-global
--- Standalone client fallback.
---
--- No framework means no login event, so the player counts as loaded once the
--- session is active. Scripts waiting on petals_bridge:playerLoaded still get their
--- event and still run.

if not Bridge.register('standalone') then return end

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(250) end

    Bridge.identity = Normalize.identity('standalone', 'standalone', GetPlayerName(PlayerId()), '')
    Bridge.setJob(Normalize.job())
    Bridge.setLoaded(true)
end)

-- No character screen, so the first spawnmanager spawn of the session is the
-- login. Later ones are respawns after death.
local spawned = false

AddEventHandler('playerSpawned', function()
    if spawned then return end
    spawned = true
    Bridge.spawnSelect(false, true)
end)
