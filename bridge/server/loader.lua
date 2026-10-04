---@diagnostic disable: lowercase-global
--- Server-side framework bridge.
---
--- Each framework file below fills in Bridge.impl if it is the active one.
--- Nothing outside bridge/ touches a framework directly - that is the whole
--- point of the resource.

if not Debug then
    print('^3[petals_bridge]^7 shared/debug.lua was not loaded - run "refresh" then "restart petals_bridge". Logging is disabled until then.')
    Debug = setmetatable({}, { __index = function() return function() end end })
end

Bridge = {
    name = nil,   ---@type 'qbox'|'qbcore'|'esx'|'standalone'|nil
    core = nil,   ---@type table|nil
    impl = {},    ---@type table The active framework's function table.
    ready = false,
}

local function started(resource)
    return GetResourceState(resource) == 'started'
end

--- Order matters. Qbox ships a qb-core compatibility layer and registers itself
--- as providing 'qb-core', so a qb-core check would match on a Qbox server and
--- quietly pick the slower, lossier path. Qbox is checked first for that reason.
function Bridge.detect()
    local forced = Config.Framework

    if forced and forced ~= 'auto' then
        Bridge.name = forced
        Debug.log('bridge', 'framework forced to %s by Config.Framework', forced)
        return forced
    end

    if started('qbx_core') then
        Bridge.name = 'qbox'
    elseif started('qb-core') then
        Bridge.name = 'qbcore'
    elseif started('es_extended') then
        Bridge.name = 'esx'
    else
        Bridge.name = 'standalone'
        Debug.warn('no supported framework found - running standalone. Money, jobs and gangs will be no-ops until you wire them up in bridge/server/standalone.lua.')
    end

    Debug.log('bridge', 'detected framework: %s', Bridge.name)

    return Bridge.name
end

--- Framework files call this to claim the slot. Registering under a name that is
--- not the detected one is a no-op, which is what lets all four files load
--- unconditionally and sort themselves out.
---@param name string
---@param impl table
function Bridge.register(name, impl)
    if Bridge.name ~= name then return false end

    Bridge.impl = impl
    Bridge.ready = true
    Debug.log('bridge', '%s implementation registered (%d functions)', name, (function()
        local n = 0
        for _ in pairs(impl) do n = n + 1 end
        return n
    end)())

    return true
end

--- Every public call funnels through here.
---
--- A missing function must not take the calling resource down with it: a Petals
--- script asking for a gang on a gangless server should get nil and a console
--- line, not a hard error inside someone else's callback. Same for a framework
--- file that throws - we log it and return nil.
---@param fn string
local function call(fn, ...)
    if not Bridge.ready then
        Debug.err('Bridge.%s called before a framework was detected. Add "petals_bridge" to your dependencies so it starts first.', fn)
        return nil
    end

    local handler = Bridge.impl[fn]

    if not handler then
        Debug.err('Bridge.%s is not implemented for %s', fn, tostring(Bridge.name))
        return nil
    end

    local ok, a, b, c = pcall(handler, ...)

    if not ok then
        Debug.err('Bridge.%s threw on %s: %s', fn, tostring(Bridge.name), tostring(a))
        return nil
    end

    return a, b, c
end

Bridge.call = call

-- Player load state ------------------------------------------------------------

--- Which players have a character loaded right now.
---@type table<number, boolean>
local loaded = {}

--- Framework files call this from their own login/logout events, so
--- petals_bridge:playerLoaded / playerUnloaded fire from exactly one place and only
--- on a real change. That matters because frameworks double up: a logout can be
--- followed by a disconnect, and both would otherwise count as an unload.
---@param src number|string
---@param state boolean
function Bridge.setLoaded(src, state)
    src = tonumber(src)
    if not src or (loaded[src] == true) == state then return end

    loaded[src] = state or nil
    Debug.log('player', 'player %s %s', src, state and 'loaded' or 'unloaded')

    TriggerEvent(state and 'petals_bridge:playerLoaded' or 'petals_bridge:playerUnloaded', src)
end

AddEventHandler('playerDropped', function()
    Bridge.setLoaded(source, false)
end)

-- Jobs and money, as they change ------------------------------------------------

--- The job each loaded player had when the bridge last looked.
---@type table<number, PetalsJob>
local lastJob = {}

AddEventHandler('petals_bridge:playerLoaded', function(src) lastJob[src] = call('getJob', src) end)
AddEventHandler('petals_bridge:playerUnloaded', function(src) lastJob[src] = nil end)

--- Framework files call this whenever the framework says a player's job or duty
--- changed. It compares with what the bridge saw last, so a framework that
--- fires twice, or fires with nothing new, sends nothing:
---   petals_bridge:jobChanged  (src, job, previous) - a different job or grade
---   petals_bridge:dutyChanged (src, onDuty, job)   - same job, duty flipped
function Bridge.jobUpdated(src)
    src = tonumber(src)
    if not src then return end

    local job = call('getJob', src)
    if not job then return end

    local before = lastJob[src]
    lastJob[src] = job

    -- First time seen (logging in) is not a change.
    if not before then return end

    if before.name ~= job.name or before.grade ~= job.grade then
        TriggerEvent('petals_bridge:jobChanged', src, job, before)
    elseif before.onDuty ~= job.onDuty then
        TriggerEvent('petals_bridge:dutyChanged', src, job.onDuty, job)
    end
end

--- Framework files call this from their money events, with the framework's
--- own account name. Fires petals_bridge:moneyChanged (src, account, amount,
--- action, reason, balance): account as Petals scripts name it ('cash', 'bank'),
--- action 'add' | 'remove' | 'set' (a set's amount is the new balance).
function Bridge.moneyChanged(src, account, amount, action, reason)
    src, amount = tonumber(src), tonumber(amount)
    if not src or not amount or type(account) ~= 'string' then return end

    account = Normalize.accountFrom(account, Bridge.name)
    local balance = call('getMoney', src, account)

    TriggerEvent('petals_bridge:moneyChanged', src, account, amount, action, reason, balance)
end

-- petals_bridge restarting mid-session misses every login event, so the players
-- already in game are recorded quietly - no playerLoaded, since nothing new
-- loaded - so their eventual logout still fires playerUnloaded. Deferred a
-- second because the ESX and QB files fetch their core object in a thread.
SetTimeout(1000, function()
    for _, src in ipairs(call('getOnlinePlayers') or {}) do
        src = tonumber(src)
        if src then
            loaded[src] = true
            lastJob[src] = call('getJob', src)
        end
    end
end)

--- Detection runs here, synchronously, and NOT in a CreateThread.
---
--- The framework files below this one call Bridge.register at the top level as
--- they load. CreateThread defers to the next tick, which is after every one of
--- those files has already run - so detection would still be nil when they tried
--- to claim their slot and all four would silently decline. GetResourceState is
--- safe at load time, so there is no reason to defer.
Bridge.detect()
