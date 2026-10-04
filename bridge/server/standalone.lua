---@diagnostic disable: lowercase-global
--- Standalone fallback.
---
--- This exists so a Petals script on an unsupported server degrades into something
--- you can diagnose instead of erroring inside a callback and leaving the player
--- staring at nothing. Every call returns a sane empty value and says once, in
--- console, what it would have done.
---
--- It is also the template for wiring up a custom core: fill these in and the
--- whole Petals catalogue works on your framework without touching any script.

local impl = {}

--- One line per function, not per call. A money function hit every frame would
--- otherwise bury the console.
local warned = {}

local function once(fn, fmt, ...)
    if warned[fn] then return end
    warned[fn] = true
    Debug.warn(('[standalone] %s'):format(fmt:format(...)))
end

-- Identity -------------------------------------------------------------------

function impl.getPlayer(src)
    return { source = src }
end

--- Falling back to the rockstar license keeps per-player storage working, so
--- scripts that only need a stable key still function on a bare server.
function impl.getIdentifier(src)
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if id:sub(1, 8) == 'license:' then return id end
    end

    return ('src:%s'):format(src)
end

function impl.getIdentity(src)
    local name = GetPlayerName(src) or ''
    return Normalize.identity(impl.getIdentifier(src), impl.getIdentifier(src), name, '')
end

function impl.getName(src)
    return GetPlayerName(src) or ('player:%s'):format(src)
end

function impl.getSource(identifier)
    for _, src in ipairs(GetPlayers()) do
        if impl.getIdentifier(tonumber(src)) == identifier then return tonumber(src) end
    end

    return nil
end

function impl.getOnlinePlayers()
    local out = {}

    for _, src in ipairs(GetPlayers()) do
        out[#out + 1] = tonumber(src)
    end

    return out
end

function impl.getOfflineName(identifier)
    once('getOfflineName', 'no framework - cannot look up offline name for %s', tostring(identifier))
    return nil
end

-- Money ----------------------------------------------------------------------

function impl.getMoney(src, account)
    once('getMoney', 'no economy wired up - getMoney(%s) returns 0', tostring(account))
    return 0
end

function impl.addMoney(src, account, amount)
    once('addMoney', 'no economy wired up - %s would have received %s %s',
        GetPlayerName(src) or src, tostring(amount), tostring(account))
    return true
end

--- Returns false, not true. A charge that silently "succeeds" without taking
--- money is how you hand out free items on a misconfigured server.
function impl.removeMoney(src, account, amount)
    once('removeMoney', 'no economy wired up - refusing to charge %s %s %s',
        GetPlayerName(src) or src, tostring(amount), tostring(account))
    return false
end

function impl.addOfflineMoney(identifier, account, amount)
    once('addOfflineMoney', 'no economy wired up - refusing to pay %s %s to %s',
        tostring(amount), tostring(account), tostring(identifier))
    return false
end

-- Job / gang -----------------------------------------------------------------

function impl.getJob()
    return Normalize.job()
end

function impl.setJob()
    once('setJob', 'no framework - setJob ignored')
    return false
end

function impl.setDuty()
    return false
end

function impl.getGang()
    return nil
end

function impl.setGang()
    once('setGang', 'no framework - setGang ignored')
    return false
end

-- Metadata -------------------------------------------------------------------
-- Kept in memory for the session so scripts that stash a flag still behave
-- correctly while a player is connected. It is deliberately not persisted:
-- pretending to save would be worse than plainly not saving.

local meta = {}

function impl.getMetadata(src, key)
    local id = impl.getIdentifier(src)
    return meta[id] and meta[id][key] or nil
end

function impl.setMetadata(src, key, value)
    local id = impl.getIdentifier(src)
    meta[id] = meta[id] or {}
    meta[id][key] = value

    once('setMetadata', 'no framework - metadata is session-only and will not persist')
    return true
end

AddEventHandler('playerDropped', function()
    meta[impl.getIdentifier(source)] = nil
end)

-- Permissions ----------------------------------------------------------------

--- Falls back to the server ACE system, which exists on every FiveM server
--- whether or not a framework is installed.
function impl.getGroup(src)
    return IsPlayerAceAllowed(src, 'command') and 'admin' or 'user'
end

function impl.isAdmin(src)
    return IsPlayerAceAllowed(src, 'command')
end

-- No characters, so nothing to log out to.
function impl.logout()
    return false
end

-- No medical or police scripts to ask; the export's own checks still run.
function impl.getCondition()
    return nil
end

-- Nothing saves a position without a framework.
function impl.getPosition()
    return nil
end

-- No jobs without a framework.
function impl.getJobInfo() return nil end
function impl.getJobs() return {} end
function impl.saveJob() return false end
function impl.deleteJob() return false end
function impl.getEmployees() return {} end
function impl.setEmployee() return false end
function impl.removeEmployee() return false end

-- No garage system to park a vehicle in.
function impl.getOwnedVehicles() return {} end

function impl.getVehicleOwner()
    return nil
end

-- Nobody owns a vehicle without a framework, so there is nothing to list or
-- save. A garage on standalone shows an empty list rather than erroring.
function impl.getCharacterVehicles() return {} end
function impl.getVehicle() return nil end

function impl.saveVehicle(plate)
    once('saveVehicle', 'saveVehicle(%s): no framework to save an owned vehicle to', tostring(plate))
    return false
end

function impl.setVehicleOwner() return false end
function impl.deleteVehicle() return false end

-- No gangs without a framework.
function impl.getGangInfo() return nil end
function impl.getGangs() return {} end

-- Items: only ox_inventory (bridge/server/items.lua); nothing to fall back to.

function impl.getItemCount(_, item)
    once('getItemCount', 'getItemCount(%s): no inventory to count in', tostring(item))
    return 0
end

function impl.removeItem(_, item)
    once('removeItem', 'removeItem(%s): no inventory to remove from', tostring(item))
    return false
end

function impl.setItemMetadata() return false end
function impl.removeItemSlot() return false end
function impl.ensureItems() return {} end

function impl.registerUsableItem(item)
    once('registerUsableItem', 'registerUsableItem(%s): no framework to register it with', tostring(item))
    return false
end
function impl.getVehicleName() return nil end

function impl.giveVehicle(_, model)
    once('giveVehicle', 'no framework - cannot give an owned %s', tostring(model))
    return nil
end

-- No characters: a character select screen has nothing to list or load. These
-- return empty rather than erroring so the screen can say so plainly.
function impl.getCharacters()
    once('getCharacters', 'no framework - there are no characters to list')
    return nil
end

function impl.getAppearance() return nil end
function impl.loadCharacter() return false end
function impl.createCharacter() return nil end
function impl.deleteCharacter() return false end

if not Bridge.register('standalone', impl) then return end

-- No characters, so a player counts as loaded from the moment they join. The
-- disconnect side is handled for every framework in loader.lua.
AddEventHandler('playerJoining', function()
    Bridge.setLoaded(source, true)
end)
