---@diagnostic disable: lowercase-global
--- QB-Core server implementation.
---
--- Note GetMetaData / SetMetaData: capital D. Qbox spells the same calls with a
--- lowercase d. Getting it wrong returns nil instead of erroring, so it hides.

local impl = {}
local FW = 'qbcore'
local core

CreateThread(function()
    if GetResourceState('qb-core') ~= 'started' then return end
    core = exports['qb-core']:GetCoreObject()
end)

local function player(src)
    if not core then return nil end
    return core.Functions.GetPlayer(src)
end

-- Identity -------------------------------------------------------------------

function impl.getPlayer(src)
    return player(src)
end

function impl.getIdentifier(src)
    local p = player(src)
    return p and p.PlayerData.citizenid or nil
end

function impl.getIdentity(src)
    local p = player(src)
    if not p then return nil end

    local info = p.PlayerData.charinfo or {}

    return Normalize.identity(
        p.PlayerData.citizenid, p.PlayerData.citizenid,
        info.firstname, info.lastname, info.birthdate, info.gender, info.phone
    )
end

function impl.getName(src)
    local p = player(src)
    if not p then return GetPlayerName(src) end

    return p.Functions.GetName and p.Functions.GetName() or impl.getIdentity(src).fullname
end

function impl.getSource(identifier)
    if not core then return nil end

    local p = core.Functions.GetPlayerByCitizenId(identifier)
    return p and p.PlayerData.source or nil
end

function impl.getOnlinePlayers()
    local out = {}

    for _, p in pairs(core and core.Functions.GetQBPlayers() or {}) do
        out[#out + 1] = p.PlayerData.source
    end

    return out
end

function impl.getOfflineName(identifier)
    local row = MySQL.single.await(
        'SELECT charinfo FROM players WHERE citizenid = ?', { identifier })
    if not row or not row.charinfo then return nil end

    local ok, info = pcall(json.decode, row.charinfo)
    if not ok or not info then return nil end

    return ('%s %s'):format(info.firstname or '', info.lastname or '')
end

-- Money ----------------------------------------------------------------------

function impl.getMoney(src, account)
    local p = player(src)
    if not p then return 0 end

    return p.Functions.GetMoney(Normalize.account(account, FW)) or 0
end

function impl.addMoney(src, account, amount, reason)
    local p = player(src)
    if not p then return false end

    return p.Functions.AddMoney(Normalize.account(account, FW), amount, reason) and true or false
end

function impl.removeMoney(src, account, amount, reason)
    local p = player(src)
    if not p then return false end

    return p.Functions.RemoveMoney(Normalize.account(account, FW), amount, reason) and true or false
end

--- Money for a character who is not in the city, straight into what the
--- framework saved (players.money). Only for someone offline: an online
--- character's save would write over it, so exports.lua uses addMoney for them.
function impl.addOfflineMoney(identifier, account, amount)
    local name = Normalize.account(account, FW)
    if type(name) ~= 'string' or not name:match('^[%w_]+$') then return false end

    local path = '$.' .. name
    local changed = MySQL.update.await(
        'UPDATE players SET money = JSON_SET(money, ?, COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(money, ?)) AS SIGNED), 0) + ?) WHERE citizenid = ?',
        { path, path, amount, identifier })

    return (tonumber(changed) or 0) > 0
end

-- Job ------------------------------------------------------------------------

function impl.getJob(src)
    local p = player(src)
    if not p then return nil end

    local job = p.PlayerData.job or {}
    local level, label = Normalize.grade(job.grade)

    return Normalize.job(job.name, job.label, level, label,
        job.onduty, job.isboss, job.payment)
end

function impl.setJob(src, name, grade)
    local p = player(src)
    if not p then return false end

    return p.Functions.SetJob(name, grade or 0) and true or false
end

function impl.setDuty(src, duty)
    local p = player(src)
    if not p then return false end

    p.Functions.SetJobDuty(duty)
    return true
end

-- Gang -----------------------------------------------------------------------

function impl.getGang(src)
    local p = player(src)
    if not p then return nil end

    local gang = p.PlayerData.gang or {}
    local level, label = Normalize.grade(gang.grade)

    return Normalize.gang(gang.name, gang.label, level, label, gang.isboss)
end

function impl.setGang(src, name, grade)
    local p = player(src)
    if not p then return false end

    return p.Functions.SetGang(name, grade or 0) and true or false
end

-- Metadata -------------------------------------------------------------------

function impl.getMetadata(src, key)
    local p = player(src)
    if not p then return nil end

    return p.Functions.GetMetaData(key)
end

function impl.setMetadata(src, key, value)
    local p = player(src)
    if not p then return false end

    p.Functions.SetMetaData(key, value)
    return true
end

-- Permissions ----------------------------------------------------------------

function impl.getGroup(src)
    if not core then return 'user' end

    for _, group in ipairs(Config.AdminGroups) do
        if core.Functions.HasPermission(src, group) then return group end
    end

    return 'user'
end

function impl.isAdmin(src)
    if not core then return false end

    -- QB accepts a table of permission levels and returns true if the player has
    -- any of them, so this is one call rather than a loop.
    return core.Functions.HasPermission(src, Config.AdminGroups) and true or false
end

-- Session ----------------------------------------------------------------------

--- Back to character select: the same two steps qb-multicharacter's own logout
--- takes (unload the player, then open the character screen).
function impl.logout(src)
    if not player(src) then return false end

    core.Player.Logout(src)
    TriggerClientEvent('qb-multicharacter:client:chooseChar', src)
    return true
end

--- 'dead', 'downed' or 'cuffed', as qb-ambulancejob and qb-policejob record it.
function impl.getCondition(src)
    local p = player(src)
    local meta = p and p.PlayerData.metadata
    if not meta then return nil end

    if meta.isdead then return 'dead' end
    if meta.inlaststand then return 'downed' end
    if meta.ishandcuffed then return 'cuffed' end
    return nil
end

--- QB-Core saves a vector3 with no heading.
function impl.getPosition(src)
    local p = player(src)
    return p and Normalize.position(p.PlayerData.position) or nil
end

-- Employment -------------------------------------------------------------------
-- One job per character, kept as a JSON blob in players.job. Online players
-- change through the player object; offline ones get the blob rewritten the way
-- QB-Core would have built it.

local function sharedJob(name)
    return core and core.Shared and core.Shared.Jobs and core.Shared.Jobs[name] or nil
end

function impl.getJobInfo(name)
    local job = sharedJob(name)
    if not job then return nil end

    local grades = {}

    for level, grade in pairs(job.grades or {}) do
        grades[#grades + 1] = Normalize.gradeInfo(level, grade.name, grade.isboss, grade.payment)
    end

    return Normalize.jobInfo(name, job.label, grades, job)
end

function impl.getJobs()
    local list = {}
    for name in pairs(core and core.Shared and core.Shared.Jobs or {}) do list[#list + 1] = impl.getJobInfo(name) end
    return list
end

--- A gang and its grades, in the same shape as getJobInfo.
function impl.getGangInfo(name)
    local gang = core and core.Shared and core.Shared.Gangs and core.Shared.Gangs[name] or nil
    if not gang then return nil end

    local grades = {}

    for level, grade in pairs(gang.grades or {}) do
        grades[#grades + 1] = Normalize.gradeInfo(level, grade.name, grade.isboss, 0)
    end

    return Normalize.jobInfo(name, gang.label, grades)
end

function impl.getGangs()
    local list = {}
    for name in pairs(core and core.Shared and core.Shared.Gangs or {}) do list[#list + 1] = impl.getGangInfo(name) end
    return list
end

--- The core object is a copy taken when it was fetched, so it goes stale when
--- a job is added. qb-core fires this after every AddJob / UpdateJob / RemoveJob.
AddEventHandler('QBCore:Server:UpdateObject', function()
    if GetResourceState('qb-core') == 'started' then core = exports['qb-core']:GetCoreObject() end
end)

--- Live only: QB-Core keeps jobs in shared/jobs.lua and never writes it, so the
--- caller saves its own copy and adds it again on every start. Fields this does
--- not manage are kept from the job as it was.
function impl.saveJob(name, data)
    if not core then return false end

    local old = sharedJob(name) or {}
    local job = {}

    for k, v in pairs(old) do job[k] = v end
    job.label, job.type = data.label, data.type or old.type
    job.defaultDuty, job.offDutyPay = data.defaultDuty, data.offDutyPay
    job.grades = {}

    for _, g in ipairs(data.grades) do
        local key = tostring(g.level)
        local grade = {}
        for k, v in pairs(old.grades and (old.grades[key] or old.grades[g.level]) or {}) do grade[k] = v end

        grade.name, grade.payment = g.label, g.salary
        grade.isboss = g.isBoss or nil
        job.grades[key] = grade
    end

    local ok
    if sharedJob(name) then
        ok = core.Functions.UpdateJob(name, job)
    else
        ok = core.Functions.AddJob(name, job)
    end

    if ok then core.Shared.Jobs[name] = job end
    return ok == true
end

function impl.deleteJob(name)
    if not core then return false end

    local ok = core.Functions.RemoveJob(name)
    if ok then core.Shared.Jobs[name] = nil end
    return ok == true
end

local function decode(value)
    if type(value) ~= 'string' then return value or {} end
    local ok, out = pcall(json.decode, value)
    return ok and out or {}
end

local function charName(info)
    info = decode(info)
    return (('%s %s'):format(info.firstname or '', info.lastname or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

function impl.getEmployees(job)
    local list, seen = {}, {}

    -- Online first: their job may be newer than the last save.
    for _, p in pairs(core and core.Functions.GetQBPlayers() or {}) do
        local data = p.PlayerData
        if data.job and data.job.name == job then
            seen[data.citizenid] = true
            list[#list + 1] = {
                id = data.citizenid,
                name = charName(data.charinfo),
                grade = Normalize.grade(data.job.grade),
                online = data.source,
                onDuty = data.job.onduty == true,
            }
        end
    end

    local rows = MySQL.query.await(
        "SELECT citizenid, charinfo, job FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, '$.name')) = ?", { job }) or {}

    for _, row in ipairs(rows) do
        if not seen[row.citizenid] and not impl.getSource(row.citizenid) then
            list[#list + 1] = {
                id = row.citizenid,
                name = charName(row.charinfo),
                grade = Normalize.grade(decode(row.job).grade),
                online = false,
                onDuty = false,
            }
        end
    end

    return list
end

--- The job blob QB-Core saves, for a character that is not online.
local function offlineJob(id, name, level)
    local job = sharedJob(name)
    if not job then return false end

    local grade = job.grades[tostring(level)] or job.grades[level]
    if not grade then return false end

    local blob = {
        name = name,
        label = job.label,
        type = job.type,
        payment = grade.payment or 0,
        onduty = false,
        isboss = grade.isboss == true,
        grade = { name = grade.name, level = level },
    }

    return (MySQL.update.await('UPDATE players SET job = ? WHERE citizenid = ?', { json.encode(blob), id }) or 0) > 0
end

function impl.setEmployee(id, job, grade)
    local src = impl.getSource(id)
    if src then return impl.setJob(src, job, grade) end

    return offlineJob(id, job, grade)
end

function impl.removeEmployee(id, job)
    local src = impl.getSource(id)

    if src then
        local current = impl.getJob(src)
        if not current or current.name ~= job then return false end
        return impl.setJob(src, 'unemployed', 0)
    end

    local row = MySQL.single.await('SELECT job FROM players WHERE citizenid = ?', { id })
    if not row or decode(row.job).name ~= job then return false end

    return offlineJob(id, 'unemployed', 0)
end

-- Vehicles ---------------------------------------------------------------------

--- Eight characters, the shape qb-vehicleshop gives: 1ABC234D style.
local function newPlate()
    local letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

    local function letter() local i = math.random(1, 26) return letters:sub(i, i) end
    local function digit() return tostring(math.random(0, 9)) end

    for _ = 1, 25 do
        local plate = digit() .. letter() .. letter() .. digit() .. digit() .. digit() .. letter() .. letter()

        if not MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1', { plate }) then
            return plate
        end
    end

    return nil
end

--- An owned vehicle, parked in `garage` (state 1 = in the garage for qb-garages).
function impl.giveVehicle(src, model, garage)
    local p = player(src)
    if not p then return nil end

    local plate = newPlate()
    if not plate then return nil end

    local hash = joaat(model)

    MySQL.insert.await(
        'INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { p.PlayerData.license, p.PlayerData.citizenid, model, hash, json.encode({ model = hash, plate = plate }), plate, garage, 1 })

    return plate
end

--- Every owned vehicle (for logs watching ownership and garages).
function impl.getOwnedVehicles()
    local list = {}

    for _, row in ipairs(MySQL.query.await('SELECT id, plate, citizenid, vehicle, garage, state FROM player_vehicles') or {}) do
        list[#list + 1] = {
            key = tostring(row.id), plate = row.plate, owner = row.citizenid, model = row.vehicle,
            garage = row.garage, state = Normalize.vehicleState(row.state),
        }
    end

    return list
end

--- Every vehicle QBCore.Shared.Vehicles knows, for a dealership.
function impl.getVehicleCatalogue()
    local shared = core and core.Shared or {}
    local out = {}

    for model, v in pairs(type(shared.Vehicles) == 'table' and shared.Vehicles or {}) do
        if type(v) == 'table' then
            out[#out + 1] = {
                model = v.model or model,
                name = v.name or model,
                brand = v.brand or '',
                label = (((v.brand or '') .. ' ' .. (v.name or model)):gsub('^%s+', '')),
                price = math.floor(tonumber(v.price) or 0),
                category = v.category or 'other',
                kind = v.type or 'automobile',
            }
        end
    end

    return out
end

--- { model, label } from QBCore.Shared.Vehicles.
function impl.getVehicleName(model)
    local shared = core and core.Shared or {}
    local v

    if type(model) == 'string' then
        v = shared.Vehicles and shared.Vehicles[model]
    else
        for _, hash in ipairs(Normalize.hashes(model)) do
            v = v or (shared.VehicleHashes and shared.VehicleHashes[hash])
        end
    end

    if not v then return nil end
    return { model = v.model, label = (((v.brand or '') .. ' ' .. (v.name or v.model)):gsub('^%s+', '')) }
end

--- The citizenid that owns a plate, or nil.
function impl.getVehicleOwner(plate)
    return MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

--- Owned vehicles for one character, and the writes a garage needs. Qbox keeps
--- the same table, so both read bridge/server/vehicles.lua.
function impl.getCharacterVehicles(identifier)
    return VehicleStore.byOwner(identifier)
end

function impl.getVehicle(plate)
    return VehicleStore.byPlate(plate)
end

function impl.saveVehicle(plate, data)
    return VehicleStore.save(plate, data)
end

function impl.deleteVehicle(plate)
    return VehicleStore.remove(plate)
end

function impl.setVehicleOwner(plate, identifier)
    return VehicleStore.setOwner(plate, identifier)
end

-- Items ------------------------------------------------------------------------
-- Used when ox_inventory is not running (bridge/server/items.lua goes to it
-- directly when it is). qb-inventory 2.x moved the item calls from the player
-- object to its own exports; older builds still have them on the player.

local function qbInventory()
    return GetResourceState('qb-inventory') == 'started'
end

function impl.getItemCount(src, item)
    if qbInventory() then
        local ok, count = pcall(function() return exports['qb-inventory']:GetItemCount(src, item) end)
        if ok and tonumber(count) then return tonumber(count) end
    end

    local p = player(src)
    local found = p and p.Functions.GetItemByName and p.Functions.GetItemByName(item)
    return found and (found.amount or found.count) or 0
end

function impl.removeItem(src, item, count)
    if qbInventory() then
        local ok, removed = pcall(function() return exports['qb-inventory']:RemoveItem(src, item, count, false, 'petals_bridge') end)
        if ok then return removed ~= false end
    end

    local p = player(src)
    return p and p.Functions.RemoveItem and p.Functions.RemoveItem(item, count) ~= false or false
end

--- qb-inventory keeps metadata under 'info'.
function impl.getItems(src, item)
    local out = {}

    if qbInventory() then
        local ok, found = pcall(function() return exports['qb-inventory']:GetItemsByName(src, item) end)
        if ok and type(found) == 'table' then
            for _, slot in ipairs(found) do out[#out + 1] = { count = slot.amount or 1, slot = slot.slot, metadata = slot.info } end
            return out
        end
    end

    local p = player(src)
    local found = p and p.Functions.GetItemsByName and p.Functions.GetItemsByName(item)

    for _, slot in ipairs(type(found) == 'table' and found or {}) do
        out[#out + 1] = { count = slot.amount or 1, slot = slot.slot, metadata = slot.info }
    end

    return out
end

--- Replaces the metadata (qb "info") of the item in one slot. qb-inventory 2.x
--- still keeps the items on the player object, so both builds go through it.
function impl.setItemMetadata(src, slot, metadata)
    local p = player(src)
    local items = p and p.PlayerData.items
    if type(items) ~= 'table' or not items[slot] then return false end

    items[slot].info = metadata
    p.Functions.SetPlayerData('items', items)
    return true
end

function impl.removeItemSlot(src, item, slot)
    if qbInventory() then
        local ok, removed = pcall(function() return exports['qb-inventory']:RemoveItem(src, item, 1, slot, 'petals_bridge') end)
        if ok then return removed ~= false end
    end

    local p = player(src)
    return p and p.Functions.RemoveItem and p.Functions.RemoveItem(item, 1, slot) ~= false or false
end

--- Items missing from QBCore.Shared.Items are added at runtime, so they work
--- straight away. Answers the names it added.
function impl.ensureItems(defs)
    if not core then return {} end

    local added = {}
    for _, def in ipairs(defs) do
        if not core.Shared.Items[def.name] then
            local ok = pcall(function()
                return exports['qb-core']:AddItem(def.name, {
                    name = def.name, label = def.label, weight = def.weight or 0,
                    type = 'item', image = def.name .. '.png', unique = def.stack == false,
                    useable = def.usable ~= false, shouldClose = def.close ~= false,
                    description = def.description or '',
                })
            end)
            if ok then added[#added + 1] = def.name end
        end
    end

    return added
end

function impl.giveItem(src, item, count, metadata)
    if qbInventory() then
        local ok, added = pcall(function()
            return exports['qb-inventory']:AddItem(src, item, count, false, metadata, 'petals_bridge')
        end)
        if ok then return added ~= false end
    end

    local p = player(src)
    return p and p.Functions.AddItem and p.Functions.AddItem(item, count, false, metadata) ~= false or false
end

function impl.registerUsableItem(item, cb)
    if not core then return false end
    core.Functions.CreateUseableItem(item, function(source, data)
        data = type(data) == 'table' and data or {}
        cb(source, { name = item, slot = data.slot, metadata = data.info or data.metadata })
    end)
    return true
end

-- Characters -------------------------------------------------------------------
-- For a character select screen that replaces qb-multicharacter.

local function license(src)
    return core and core.Functions.GetIdentifier(src, 'license') or GetPlayerIdentifierByType(src, 'license')
end

local function owns(src, citizenid)
    if type(citizenid) ~= 'string' then return false end

    local owner = MySQL.scalar.await('SELECT license FROM players WHERE citizenid = ?', { citizenid })
    return owner ~= nil and owner == license(src)
end

function impl.getCharacters(src)
    local rows = MySQL.query.await(
        'SELECT citizenid, cid, charinfo, money, job, position, UNIX_TIMESTAMP(last_updated) AS lastPlayed FROM players WHERE license = ? ORDER BY cid',
        { license(src) or '' }) or {}

    local list = {}
    for i, row in ipairs(rows) do
        local info, money, job = Normalize.json(row.charinfo), Normalize.json(row.money), Normalize.json(row.job)
        local _, gradeLabel = Normalize.grade(job.grade)

        list[#list + 1] = Normalize.character({
            id = row.citizenid, slot = row.cid or info.cid or i,
            firstname = info.firstname, lastname = info.lastname, birthdate = info.birthdate,
            gender = info.gender, nationality = info.nationality,
            job = job.label, grade = job.name ~= 'unemployed' and gradeLabel or '',
            cash = money.cash, bank = money.bank,
            lastPlayed = row.lastPlayed, position = Normalize.json(row.position),
        })
    end

    return Normalize.slots(list)
end

function impl.getAppearance(src, citizenid)
    if not owns(src, citizenid) then return nil end

    local row = MySQL.single.await('SELECT model, skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if not row then return nil end

    return { model = row.model, skin = Normalize.json(row.skin) }
end

function impl.loadCharacter(src, citizenid)
    if not core or player(src) or not owns(src, citizenid) then return false end
    if not core.Player.Login(src, citizenid) then return false end

    core.Commands.Refresh(src)
    return true
end

--- qb-multicharacter hands out QBShared.StarterItems itself, with the ID card
--- and licence filled in, so a replacement has to as well.
local function giveStarterItems(src)
    local items = core.Shared and core.Shared.StarterItems
    if not items then
        local ok, shared = pcall(function() return exports['qb-core']:GetShared('StarterItems') end)
        items = ok and shared or nil
    end
    if type(items) ~= 'table' then return end

    local p = player(src)
    if not p then return end
    local info = p.PlayerData.charinfo or {}

    local useOx = GetResourceState('ox_inventory') == 'started'

    for key, entry in pairs(items) do
        local name = type(entry) == 'table' and (entry.item or entry.name) or key
        local amount = type(entry) == 'table' and entry.amount or 1
        local metadata = {}

        if name == 'id_card' then
            metadata = { citizenid = p.PlayerData.citizenid, firstname = info.firstname, lastname = info.lastname,
                birthdate = info.birthdate, gender = info.gender, nationality = info.nationality }
        elseif name == 'driver_license' then
            metadata = { firstname = info.firstname, lastname = info.lastname, birthdate = info.birthdate,
                type = 'Class C Driver License' }
        end

        if useOx then
            exports.ox_inventory:AddItem(src, name, amount, metadata)
        elseif GetResourceState('qb-inventory') == 'started' then
            exports['qb-inventory']:AddItem(src, name, amount, false, metadata, 'petals_bridge:starterItems')
        end
    end
end

function impl.createCharacter(src, data, slot)
    if not core or player(src) then return nil end

    local owner = license(src) or ''
    local cid = math.floor(tonumber(slot) or 0)
    local taken = cid < 1 or MySQL.scalar.await('SELECT 1 FROM players WHERE license = ? AND cid = ?', { owner, cid })

    if taken then
        cid = (tonumber(MySQL.scalar.await('SELECT MAX(cid) FROM players WHERE license = ?', { owner })) or 0) + 1
    end

    local ok = core.Player.Login(src, false, {
        cid = cid,
        charinfo = {
            firstname = data.firstname, lastname = data.lastname,
            birthdate = data.birthdate, gender = data.gender == 1 and 1 or 0,
            nationality = data.nationality, cid = cid,
        },
    })
    if not ok then return nil end

    core.Commands.Refresh(src)
    giveStarterItems(src)

    local p = player(src)
    return p and p.PlayerData.citizenid or nil
end

function impl.deleteCharacter(src, citizenid)
    if not core or not owns(src, citizenid) then return false end

    core.Player.DeleteCharacter(src, citizenid)
    return true
end

if not Bridge.register(FW, impl) then return end

-- Player load state -------------------------------------------------------------

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    Bridge.setLoaded(player and player.PlayerData and player.PlayerData.source, true)
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    Bridge.setLoaded(src, false)
end)

-- Job, duty and money changes -----------------------------------------------------

AddEventHandler('QBCore:Server:OnJobUpdate', function(src) Bridge.jobUpdated(src) end)
AddEventHandler('QBCore:Server:SetDuty', function(src) Bridge.jobUpdated(src) end)

AddEventHandler('QBCore:Server:OnMoneyChange', function(src, account, amount, action, reason)
    Bridge.moneyChanged(src, account, amount, action, reason)
end)
