---@diagnostic disable: lowercase-global
--- The public client surface.
---
--- All of these read the cache the framework files keep current. None of them
--- make a server round trip, so they are safe to call in a loop or a nearby-check
--- thread.

exports('isReady', function() return Bridge.ready end)
exports('isLoaded', function() return Bridge.loaded end)
exports('getFramework', function() return Bridge.name end)

exports('getJob', function() return Bridge.job end)
exports('getGang', function() return Bridge.gang end)
exports('getIdentity', function() return Bridge.identity end)

exports('getIdentifier', function()
    return Bridge.identity and Bridge.identity.identifier or nil
end)

--- `{ hunger, thirst, stress }`, each 0-100, for a HUD to draw. Any the
--- framework does not keep is nil - draw nothing rather than a full bar.
--- Nil altogether on standalone, or on ESX before esx_status has ticked.
exports('getNeeds', function() return Bridge.getNeeds() end)

--- `{ cash, bank }` as the client already knows it, or nil where it cannot be
--- read without asking the server.
exports('getMoney', function() return Bridge.getMoney() end)

exports('hasJob', function(name, minGrade)
    local job = Bridge.job
    if not job or job.name ~= name then return false end

    return job.grade >= (minGrade or 0)
end)

exports('hasGang', function(name, minGrade)
    local gang = Bridge.gang
    if not gang or gang.name ~= name then return false end

    return gang.grade >= (minGrade or 0)
end)

exports('isOnDuty', function()
    return Bridge.job and Bridge.job.onDuty or false
end)

exports('isBoss', function()
    return Bridge.job and Bridge.job.isBoss or false
end)

--- Hand the character back to the framework once a spawn selector has placed
--- the ped. Marks the player loaded on QB-Core and Qbox (and opens the creator
--- for a new character); ESX and standalone loaded before the selector opened,
--- so there it does nothing.
---@param isNew boolean
exports('finishSpawn', function(isNew)
    Bridge.finishSpawn(isNew == true)
end)

--- Blocks (up to timeout ms, default 5000) until the ped wears a real look rather
--- than the game's default story ped. Call before fading in after a spawn.
---@param timeout number|nil
---@return boolean
exports('waitForLook', function(timeout)
    return Bridge.waitForLook(tonumber(timeout))
end)

--- True while the player is building or editing their look (the new-character
--- creator, or a clothing shop). Anything that would cover it should wait - see
--- Bridge.waitForAppearance in init.lua.
exports('isEditingLook', function() return Bridge.isEditingLook() end)

-- Character selection ------------------------------------------------------------

--- True while the framework is waiting for a character to be picked.
exports('isSelectPending', function() return Bridge.selectPending end)

--- Recorded by Bridge.onSpawnSelect, so enterWorld knows a selector will take over.
exports('setSpawnSelector', function(resource) Bridge.setSpawnSelector(resource) end)

--- After the server loaded or created a character: hand it to the spawn
--- selector, or place it at `coords` when none is running. Blocks while ESX
--- runs the skin menu for a new character.
---@param isNew boolean
---@param coords vector4|nil
---@param direct boolean|nil skip the spawn selector and go straight to coords
exports('enterWorld', function(isNew, coords, direct)
    Bridge.enterWorld(isNew == true, coords, direct == true)
end)

--- The model hash for a Bridge.getAppearance result (freemode when unknown).
exports('getAppearanceModel', function(appearance, female)
    return Appearance.model(appearance, female)
end)

--- Dress any ped in a Bridge.getAppearance result. The ped needs the model first.
exports('applyAppearance', function(ped, appearance)
    return Appearance.apply(ped, appearance)
end)

--- Sets a vehicle's fuel (0-100) in whichever fuel script runs: ox_fuel's
--- state bag, the LegacyFuel / cdn-fuel / ps-fuel exports, or the game's own
--- fuel level when none of them do.
local FUEL_EXPORTS = { 'LegacyFuel', 'cdn-fuel', 'ps-fuel' }

exports('setFuel', function(vehicle, level)
    level = math.max(0.0, math.min(100.0, tonumber(level) or 100.0))
    if not vehicle or not DoesEntityExist(vehicle) then return false end

    if GetResourceState('ox_fuel') == 'started' then
        Entity(vehicle).state:set('fuel', level, true)
        return true
    end

    for _, resource in ipairs(FUEL_EXPORTS) do
        if GetResourceState(resource) == 'started' then
            local ok = pcall(function() exports[resource]:SetFuel(vehicle, level) end)
            if ok then return true end
        end
    end

    SetVehicleFuelLevel(vehicle, level)
    return true
end)

--- Block until the character is actually in the world.
---
--- Every Petals script opens with some version of this, and the naive version -
--- a bare `while not loaded do Wait(100) end` - hangs forever on a
--- misconfigured server with no clue as to why. The timeout turns that into a
--- console line and a false return the caller can act on.
---@param timeout number|nil Milliseconds. Defaults to 30s.
---@return boolean
exports('waitForPlayer', function(timeout)
    if Bridge.loaded then return true end

    local deadline = GetGameTimer() + (timeout or 30000)

    while not Bridge.loaded do
        if GetGameTimer() > deadline then
            Debug.warn('waitForPlayer timed out after %dms on %s - the player never loaded',
                timeout or 30000, tostring(Bridge.name))
            return false
        end

        Wait(100)
    end

    return true
end)
