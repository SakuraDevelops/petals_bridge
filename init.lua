---@diagnostic disable: lowercase-global
--- Consumer entry point. This file runs inside YOUR resource, not petals_bridge.
---
--- Add it to your shared_scripts, above your own files:
---
---     shared_scripts {
---         '@ox_lib/init.lua',
---         '@petals_bridge/init.lua',
---         'config.lua',
---     }
---
---     dependencies { 'petals_bridge' }
---
--- Then call Bridge.getJob(src) on the server, or Bridge.getJob() on the client,
--- and never write a framework check again.

local resource = GetCurrentResourceName()

-- petals_bridge loads this file itself only if someone mis-wires the manifest.
-- Bailing keeps that mistake from replacing the real Bridge table with a proxy
-- that calls back into itself.
if resource == 'petals_bridge' then return end

if GetResourceState('petals_bridge') ~= 'started' then
    error(([[

^1petals_bridge is not running, so %s cannot start.^7

  1. Make sure the petals_bridge folder is in your resources.
  2. In server.cfg, "ensure petals_bridge" must come BEFORE "ensure %s".

]]):format(resource, resource), 0)
end

local server = IsDuplicityVersion()

--- Every key resolves to an export the first time it is used, then is cached on
--- the table itself so later calls skip the metatable entirely. Exports are
--- cheap but not free, and job checks in particular get called in tight loops.
---@class Bridge
Bridge = setmetatable({}, {
    __index = function(self, key)
        local fn = function(...)
            return exports.petals_bridge[key](nil, ...)
        end

        rawset(self, key, fn)
        return fn
    end,
})

-- Bridge.getFramework() resolves through the proxy above and returns 'qbox',
-- 'qbcore', 'esx' or 'standalone'.
--
-- Call it, do not cache it in a field at load time: resources start in an order
-- you do not control, so a resource that loads before petals_bridge finishes
-- detection would capture a nil and keep it forever.
--
-- Read it for logging or a genuine special case. If you are branching on it for
-- ordinary work, that logic belongs inside the bridge instead.

if server then
    -- Server-only conveniences --------------------------------------------------

    --- Run a callback every time a player's character finishes loading.
    ---@param callback fun(src: number)
    function Bridge.onPlayerLoaded(callback)
        AddEventHandler('petals_bridge:playerLoaded', callback)
    end

    --- Run a callback every time a player's character stops being loaded: a
    --- logout to character select, or a disconnect. Fires once per load, however
    --- many of those events the framework itself sends.
    ---@param callback fun(src: number)
    function Bridge.onPlayerUnloaded(callback)
        AddEventHandler('petals_bridge:playerUnloaded', callback)
    end

    return
end

-- Client-only conveniences ----------------------------------------------------

--- Run a callback whenever the character is in the world: now, if it already
--- is, and again on every later load (a character switch loads again).
---
--- Written this way because the two orderings both happen: your resource may
--- start before the player logs in, or be restarted while they are already
--- playing. Handling only the first is the usual source of "works on restart,
--- broken on join".
---
--- `fromLoad` tells the two apart: true for a real character load, false when
--- the callback runs straight away because this resource started mid-session.
---@param callback fun(fromLoad: boolean)
function Bridge.onPlayerLoaded(callback)
    -- Subscribed before the check, so a load landing in between is not missed.
    AddEventHandler('petals_bridge:playerLoaded', function() callback(true) end)

    if exports.petals_bridge:isLoaded() then
        CreateThread(function() callback(false) end)
    end
end

---@param callback fun()
function Bridge.onPlayerUnloaded(callback)
    AddEventHandler('petals_bridge:playerUnloaded', callback)
end

--- Run a callback when the framework wants a spawn spot picked: after a
--- character is chosen or created on QB-Core and Qbox, and after the first spawn
--- of a login on ESX and standalone.
---
--- `isNew` is true for a character created just now. `loaded` is true when the
--- framework already finished loading the character; when it is false, call
--- Bridge.finishSpawn(isNew) once the ped is in place or the player never loads.
---@param callback fun(isNew: boolean, loaded: boolean)
function Bridge.onSpawnSelect(callback)
    AddEventHandler('petals_bridge:spawnSelect', callback)
    exports.petals_bridge:setSpawnSelector(GetCurrentResourceName())
end

--- Run a callback when the framework wants a character picked: on joining, and
--- after logging out. Runs straight away if that is already the case, so a
--- select screen restarted mid-selection still opens. It can run twice for one
--- request, so ignore it while your screen is already open.
---
--- Once the server has loaded or created the character (Bridge.loadCharacter /
--- Bridge.createCharacter), call Bridge.enterWorld(isNew, coords).
---@param callback fun()
function Bridge.onCharacterSelect(callback)
    AddEventHandler('petals_bridge:characterSelect', callback)

    if exports.petals_bridge:isSelectPending() then
        CreateThread(callback)
    end
end

--- Block until the player is not building or editing their look, and has not
--- been for `settle` ms (default 2000) - long enough that a save has gone
--- through. A new character's creator opens a moment after they spawn; this
--- waits for it to open and close. Returns straight away (after `settle`) when
--- no creator is involved. Call from a thread.
---@param settle number|nil
function Bridge.waitForAppearance(settle)
    settle = tonumber(settle) or 2000
    local calm = nil

    while true do
        if exports.petals_bridge:isEditingLook() then
            calm = nil
        else
            calm = calm or GetGameTimer()
            if GetGameTimer() - calm >= settle then return end
        end

        Wait(200)
    end
end

---@param callback fun(job: PetalsJob)
function Bridge.onJobChanged(callback)
    AddEventHandler('petals_bridge:jobChanged', callback)
end

---@param callback fun(gang: PetalsGang)
function Bridge.onGangChanged(callback)
    AddEventHandler('petals_bridge:gangChanged', callback)
end
