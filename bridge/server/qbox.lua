---@diagnostic disable: lowercase-global
--- Qbox server implementation.
---
--- Qbox exposes everything as exports on qbx_core, so there is no core object to
--- hold. Note GetMetadata / SetMetadata: lowercase 'd'. QB-Core spells the same
--- calls GetMetaData / SetMetaData with a capital D, and mixing them up fails
--- silently rather than erroring - it just returns nil forever.

local impl = {}
local FW = 'qbox'

local function player(src)
    return exports.qbx_core:GetPlayer(src)
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
    local id = impl.getIdentity(src)
    return id and id.fullname or GetPlayerName(src)
end

function impl.getSource(identifier)
    local p = exports.qbx_core:GetPlayerByCitizenId(identifier)
    return p and p.PlayerData.source or nil
end

function impl.getOnlinePlayers()
    local out = {}

    for _, p in pairs(exports.qbx_core:GetQBPlayers() or {}) do
        out[#out + 1] = p.PlayerData.source
    end

    return out
end

--- Offline lookups hit the database directly. Every framework stores characters
--- differently, so this is the one place a raw query is the right answer.
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
    return exports.qbx_core:GetMoney(src, Normalize.account(account, FW)) or 0
end

function impl.addMoney(src, account, amount, reason)
    return exports.qbx_core:AddMoney(src, Normalize.account(account, FW), amount, reason) and true or false
end

function impl.removeMoney(src, account, amount, reason)
    return exports.qbx_core:RemoveMoney(src, Normalize.account(account, FW), amount, reason) and true or false
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
    return exports.qbx_core:SetJob(src, name, grade or 0) and true or false
end

function impl.setDuty(src, duty)
    exports.qbx_core:SetJobDuty(src, duty)
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
    return exports.qbx_core:SetGang(src, name, grade or 0) and true or false
end

--- A gang and its grades, in the same shape as getJobInfo.
function impl.getGangInfo(name)
    local gang = exports.qbx_core:GetGang(name)
    if not gang then return nil end

    local grades = {}

    for level, grade in pairs(gang.grades or {}) do
        grades[#grades + 1] = Normalize.gradeInfo(level, grade.name, grade.isboss, 0)
    end

    return Normalize.jobInfo(name, gang.label, grades)
end

function impl.getGangs()
    local list = {}
    for name in pairs(exports.qbx_core:GetGangs() or {}) do list[#list + 1] = impl.getGangInfo(name) end
    return list
end

-- Metadata -------------------------------------------------------------------

function impl.getMetadata(src, key)
    return exports.qbx_core:GetMetadata(src, key)
end

function impl.setMetadata(src, key, value)
    exports.qbx_core:SetMetadata(src, key, value)
    return true
end

-- Permissions ----------------------------------------------------------------

-- Qbox staff ranks are ACE permissions ('admin', 'god', ...), granted in
-- permissions.cfg the same way QB-Core does it. Do NOT use qbx_core's
-- HasGroup/GetGroups here: in Qbox a "group" is a job or gang, so those would
-- miss real staff and treat anyone with a job called 'admin' or 'owner' as one.

function impl.getGroup(src)
    for _, group in ipairs(Config.AdminGroups) do
        if IsPlayerAceAllowed(src, group) then return group end
    end

    return 'user'
end

function impl.isAdmin(src)
    return impl.getGroup(src) ~= 'user'
end

-- Session ----------------------------------------------------------------------

--- Back to character select. qbx_core saves the character and opens its own
--- multicharacter screen.
function impl.logout(src)
    if not player(src) then return false end

    exports.qbx_core:Logout(src)
    return true
end

--- 'dead', 'downed' or 'cuffed', as qbx_medical and qbx_police record it.
function impl.getCondition(src)
    local p = player(src)
    local meta = p and p.PlayerData.metadata
    if not meta then return nil end

    if meta.isdead then return 'dead' end
    if meta.inlaststand then return 'downed' end
    if meta.ishandcuffed then return 'cuffed' end
    return nil
end

--- The position saved for the loaded character (a vector4), not where the ped
--- stands right now.
function impl.getPosition(src)
    local p = player(src)
    return p and Normalize.position(p.PlayerData.position) or nil
end

-- Employment -------------------------------------------------------------------
-- Qbox keeps every job a character holds in player_groups (multi-job), and its
-- job functions take a citizenid whether or not that character is online.

function impl.getJobInfo(name)
    local job = exports.qbx_core:GetJob(name)
    if not job then return nil end

    local grades = {}

    for level, grade in pairs(job.grades or {}) do
        grades[#grades + 1] = Normalize.gradeInfo(level, grade.name, grade.isboss, grade.payment)
    end

    return Normalize.jobInfo(name, job.label, grades, job)
end

function impl.getJobs()
    local list = {}
    for name in pairs(exports.qbx_core:GetJobs() or {}) do list[#list + 1] = impl.getJobInfo(name) end
    return list
end

--- Live only (commitToFile = false): qbx_core's own save rewrites all of
--- jobs.lua and drops each job's `type`. The caller keeps its own copy and
--- saves it again on every start. Fields this does not manage (and extra grade
--- fields) are kept from the job as it was.
function impl.saveJob(name, data)
    local old = exports.qbx_core:GetJob(name) or {}
    local job = {}

    for k, v in pairs(old) do job[k] = v end
    job.label, job.type = data.label, data.type or old.type
    job.defaultDuty, job.offDutyPay = data.defaultDuty, data.offDutyPay
    job.grades = {}

    for _, g in ipairs(data.grades) do
        local grade = {}
        for k, v in pairs(old.grades and old.grades[g.level] or {}) do grade[k] = v end

        grade.name, grade.payment = g.label, g.salary
        grade.isboss = g.isBoss or nil
        grade.bankAuth = g.isBoss or nil
        job.grades[g.level] = grade
    end

    return exports.qbx_core:CreateJob(name, job, false) == true
end

function impl.deleteJob(name)
    return exports.qbx_core:RemoveJob(name, false) == true
end

local function charName(info)
    if type(info) == 'string' then
        local ok, decoded = pcall(json.decode, info)
        info = ok and decoded or nil
    end

    info = info or {}
    return (('%s %s'):format(info.firstname or '', info.lastname or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

function impl.getEmployees(job)
    local rows = exports.qbx_core:GetGroupMembers(job, 'job') or {}
    local list, offline = {}, {}

    for _, row in ipairs(rows) do
        local entry = { id = row.citizenid, grade = tonumber(row.grade) or 0, online = false, onDuty = false, name = '' }
        local p = exports.qbx_core:GetPlayerByCitizenId(row.citizenid)

        if p and not p.Offline then
            local data = p.PlayerData
            entry.online = data.source
            entry.name = charName(data.charinfo)
            entry.onDuty = data.job and data.job.name == job and data.job.onduty == true
        else
            offline[#offline + 1] = row.citizenid
        end

        list[#list + 1] = entry
    end

    if #offline > 0 then
        local names = {}

        for _, row in ipairs(MySQL.query.await('SELECT citizenid, charinfo FROM players WHERE citizenid IN (?)', { offline }) or {}) do
            names[row.citizenid] = charName(row.charinfo)
        end

        for _, entry in ipairs(list) do
            if not entry.online then entry.name = names[entry.id] or entry.id end
        end
    end

    return list
end

function impl.setEmployee(id, job, grade)
    local p = exports.qbx_core:GetPlayerByCitizenId(id) or exports.qbx_core:GetOfflinePlayer(id)
    if not p then return false end

    -- Already holds it: only the grade changes, their primary job stays put.
    -- New to it: it becomes their primary job, the way qbx_core hires.
    if p.PlayerData.jobs and p.PlayerData.jobs[job] ~= nil then
        return exports.qbx_core:AddPlayerToJob(id, job, grade) == true
    end

    return exports.qbx_core:SetJob(id, job, grade) == true
end

function impl.removeEmployee(id, job)
    return exports.qbx_core:RemovePlayerFromJob(id, job) == true
end

-- Vehicles ---------------------------------------------------------------------

--- An owned vehicle, parked in `garage`. qbx_vehicles makes the plate and runs
--- its createPlayerVehicle hooks, the same path the vehicle shop takes.
function impl.giveVehicle(src, model, garage)
    local p = player(src)
    if not p then return nil end

    local id, err = exports.qbx_vehicles:CreatePlayerVehicle({
        model = model,
        citizenid = p.PlayerData.citizenid,
        garage = garage,
    })

    if not id then
        Debug.warn('giveVehicle: qbx_vehicles refused %s (%s)', tostring(model), err and err.message or 'no reason given')
        return nil
    end

    local vehicle = exports.qbx_vehicles:GetPlayerVehicle(id)
    return vehicle and vehicle.props and vehicle.props.plate or ''
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

--- { model, label } from qbx_core's vehicle list. Its lookups hand back the
--- whole list for an unknown key, hence the check on what came back.
function impl.getVehicleName(model)
    local v

    if type(model) == 'string' then
        v = exports.qbx_core:GetVehiclesByName(model)
        if type(v) ~= 'table' or v.model ~= model then v = nil end
    else
        for _, hash in ipairs(Normalize.hashes(model)) do
            local found = exports.qbx_core:GetVehiclesByHash(hash)
            if type(found) == 'table' and found.hash == hash then v = found break end
        end
    end

    if not v then return nil end
    return { model = v.model, label = (((v.brand or '') .. ' ' .. (v.name or v.model)):gsub('^%s+', '')) }
end

--- Every vehicle the framework knows how to sell, as a dealership needs it.
--- Called once and kept by the caller: this is nine hundred rows on a stock
--- Qbox, and rebuilding it per customer would be nine hundred rows per browse.
function impl.getVehicleCatalogue()
    local all = exports.qbx_core:GetVehiclesByName()
    local out = {}

    for model, v in pairs(type(all) == 'table' and all or {}) do
        if type(v) == 'table' and type(v.model) == 'string' then
            out[#out + 1] = {
                model = v.model,
                name = v.name or v.model,
                brand = v.brand or '',
                label = (((v.brand or '') .. ' ' .. (v.name or v.model)):gsub('^%s+', '')),
                price = math.floor(tonumber(v.price) or 0),
                category = v.category or 'other',
                kind = v.type or 'automobile',
            }
        elseif type(v) ~= 'table' then
            -- A list keyed by something else; the model is the key.
            out[#out + 1] = { model = model, name = model, brand = '', label = model, price = 0, category = 'other', kind = 'automobile' }
        end
    end

    return out
end

--- The citizenid that owns a plate, or nil. Plates are stored trimmed.
function impl.getVehicleOwner(plate)
    return MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
end

--- Owned vehicles for one character, with their saved properties, and the two
--- writes a garage needs. The table is player_vehicles, the same one QB-Core
--- uses, so the work lives in bridge/server/vehicles.lua.
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
-- Qbox always runs ox_inventory, which Items (bridge/server/items.lua) talks to
-- directly; only usable items go through the core.

--- Qbox is always ox_inventory, so this is only reached if it is not running.
function impl.giveItem(src, item, count, metadata)
    local ok, added = pcall(function() return exports.ox_inventory:AddItem(src, item, count, metadata) end)
    return ok and added ~= false
end

function impl.registerUsableItem(item, cb)
    -- ox_inventory hands qbx_core the slot that was used; it is passed on so a
    -- script can tell two copies of the same item apart.
    exports.qbx_core:CreateUseableItem(item, function(source, data)
        data = type(data) == 'table' and data or {}
        cb(source, { name = item, slot = data.slot, metadata = data.metadata })
    end)
    return true
end

-- Characters -------------------------------------------------------------------
-- For a character select screen that replaces qbx_core's own (set
-- characters.useExternalCharacters = true in qbx_core/config/client.lua).

local function licenses(src)
    return GetPlayerIdentifierByType(src, 'license'), GetPlayerIdentifierByType(src, 'license2')
end

--- True when the citizenid belongs to this player's Rockstar account.
local function owns(src, citizenid)
    if type(citizenid) ~= 'string' then return false end

    local owner = MySQL.scalar.await('SELECT license FROM players WHERE citizenid = ?', { citizenid })
    if not owner then return false end

    local license, license2 = licenses(src)
    return owner == license or owner == license2
end

function impl.getCharacters(src)
    local license, license2 = licenses(src)
    local rows = MySQL.query.await(
        'SELECT citizenid, cid, charinfo, money, job, position, UNIX_TIMESTAMP(last_logged_out) AS lastPlayed FROM players WHERE license = ? OR license = ? ORDER BY cid',
        { license or '', license2 or '' }) or {}

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

--- The saved look for a preview ped: { model = string|number, skin = table }.
function impl.getAppearance(src, citizenid)
    if not owns(src, citizenid) then return nil end

    local row = MySQL.single.await('SELECT model, skin FROM playerskins WHERE citizenid = ? AND active = 1', { citizenid })
    if not row then return nil end

    return { model = row.model, skin = Normalize.json(row.skin) }
end

function impl.loadCharacter(src, citizenid)
    if player(src) or not owns(src, citizenid) then return false end

    return exports.qbx_core:Login(src, citizenid) == true
end

--- qbx_core hands out its starterItems only from its own create callback, so a
--- character made anywhere else would start empty.
local function giveStarterItems(src)
    if GetResourceState('ox_inventory') ~= 'started' then return end

    local chunk = LoadResourceFile('qbx_core', 'config/shared.lua')
    local fn = chunk and load(chunk, '@@qbx_core/config/shared.lua', 't', _ENV)
    local ok, shared = pcall(fn or error)
    local items = ok and type(shared) == 'table' and shared.starterItems
    if type(items) ~= 'table' then return end

    local deadline = GetGameTimer() + 10000
    while not exports.ox_inventory:GetInventory(src) do
        if GetGameTimer() > deadline then return end
        Wait(100)
    end

    for _, item in ipairs(items) do
        local metadata = item.metadata
        if type(metadata) == 'function' then
            local fine, value = pcall(metadata, src)
            metadata = fine and value or nil
        end
        exports.ox_inventory:AddItem(src, item.name, item.amount, metadata)
    end
end

--- data: { firstname, lastname, birthdate = 'YYYY-MM-DD', gender = 0|1, nationality }
--- slot: the empty slot it was made in, kept as the cid so it stays there.
--- Validate before calling: this trusts what it is given.
function impl.createCharacter(src, data, slot)
    if player(src) then return nil end

    local license, license2 = licenses(src)
    local cid = math.floor(tonumber(slot) or 0)
    local taken = cid < 1 or MySQL.scalar.await('SELECT 1 FROM players WHERE (license = ? OR license = ?) AND cid = ?',
        { license or '', license2 or '', cid })

    if taken then
        cid = (tonumber(MySQL.scalar.await('SELECT MAX(cid) FROM players WHERE license = ? OR license = ?',
            { license or '', license2 or '' })) or 0) + 1
    end

    local ok = exports.qbx_core:Login(src, nil, {
        charinfo = {
            firstname = data.firstname, lastname = data.lastname,
            birthdate = data.birthdate, gender = data.gender == 1 and 1 or 0,
            nationality = data.nationality, backstory = 'placeholder backstory',
            cid = cid,
        },
    })
    if not ok then return nil end

    giveStarterItems(src)

    local p = player(src)
    return p and p.PlayerData.citizenid or nil
end

function impl.deleteCharacter(src, citizenid)
    if not owns(src, citizenid) then return false end

    -- qbx_core's export takes no source; ownership was checked above. It deletes
    -- from every table in characterDataTables.
    exports.qbx_core:DeleteCharacter(citizenid)
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
