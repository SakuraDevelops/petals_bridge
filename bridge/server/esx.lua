---@diagnostic disable: lowercase-global
--- ESX server implementation.
---
--- ESX is the odd one out and most of this file is absorbing that:
---   * The identifier is a rockstar license, not a citizenid. Scripts that key
---     their own tables off Bridge.getIdentifier keep working either way, but do
---     not assume the string looks like a QB citizenid.
---   * Job grades are a flat number, not a {level, name} table.
---   * There is no gang system at all - see Config.EsxGangMode.
---   * There is no isBoss flag. It is derived from the grade label instead.
---   * Cash is the account named 'money', not 'cash'.

local impl = {}
local FW = 'esx'
local core

CreateThread(function()
    if GetResourceState('es_extended') ~= 'started' then return end
    core = exports['es_extended']:getSharedObject()
end)

local function player(src)
    if not core then return nil end
    return core.GetPlayerFromId(src)
end

-- Identity -------------------------------------------------------------------

function impl.getPlayer(src)
    return player(src)
end

function impl.getIdentifier(src)
    local p = player(src)
    return p and p.getIdentifier() or nil
end

--- ESX keeps first/last name on the player object on some builds and only in the
--- users table on others. Read whichever is present rather than assuming.
function impl.getIdentity(src)
    local p = player(src)
    if not p then return nil end

    local identifier = p.getIdentifier()
    local first, last = p.get('firstName'), p.get('lastName')

    if not first then
        local row = MySQL.single.await(
            'SELECT firstname, lastname, dateofbirth, sex, phone_number FROM users WHERE identifier = ?',
            { identifier })

        if row then
            return Normalize.identity(identifier, identifier, row.firstname, row.lastname,
                row.dateofbirth, row.sex, row.phone_number)
        end
    end

    -- esx_identity keeps these on the player next to the name.
    return Normalize.identity(identifier, identifier, first, last, p.get('dateofbirth'), p.get('sex'))
end

function impl.getName(src)
    local p = player(src)
    return p and p.getName() or GetPlayerName(src)
end

function impl.getSource(identifier)
    local p = core and core.GetPlayerFromIdentifier(identifier)
    return p and p.source or nil
end

function impl.getOnlinePlayers()
    return core and core.GetPlayers() or {}
end

function impl.getOfflineName(identifier)
    local row = MySQL.single.await(
        'SELECT firstname, lastname FROM users WHERE identifier = ?', { identifier })
    if not row then return nil end

    return ('%s %s'):format(row.firstname or '', row.lastname or '')
end

-- Money ----------------------------------------------------------------------
-- ESX splits cash from accounts: getMoney/addMoney/removeMoney act on cash,
-- while bank and black money go through the account functions. Callers should
-- not have to know that, so the split happens here.

function impl.getMoney(src, account)
    local p = player(src)
    if not p then return 0 end

    local name = Normalize.account(account, FW)

    if name == 'money' then return p.getMoney() end

    local acc = p.getAccount(name)
    return acc and acc.money or 0
end

function impl.addMoney(src, account, amount, reason)
    local p = player(src)
    if not p then return false end

    local name = Normalize.account(account, FW)

    if name == 'money' then
        p.addMoney(amount, reason)
    else
        p.addAccountMoney(name, amount, reason)
    end

    return true
end

--- ESX remove functions do not report failure, so the balance is checked first.
--- Without this a script could "charge" a player who could not pay and then hand
--- over the goods anyway.
--- allowNegative lets a bank account (never cash) go below zero, for bills
--- that are owed whether or not the money is there.
function impl.removeMoney(src, account, amount, reason, allowNegative)
    local p = player(src)
    if not p then return false end

    local name = Normalize.account(account, FW)

    if name == 'money' then
        if p.getMoney() < amount then return false end
        p.removeMoney(amount, reason)
        return true
    end

    local acc = p.getAccount(name)
    if not acc or (acc.money < amount and not allowNegative) then return false end

    p.removeAccountMoney(name, amount, reason)
    return true
end

--- Money for a character who is not in the city, straight into what ESX
--- saved (users.accounts, where cash is "money"). Only for someone offline:
--- an online character's save would write over it, so exports.lua uses
--- addMoney for them.
function impl.addOfflineMoney(identifier, account, amount)
    local name = Normalize.account(account, FW)
    if type(name) ~= 'string' or not name:match('^[%w_]+$') then return false end

    local path = '$.' .. name
    local changed = MySQL.update.await(
        'UPDATE users SET accounts = JSON_SET(accounts, ?, COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(accounts, ?)) AS SIGNED), 0) + ?) WHERE identifier = ?',
        { path, path, amount, identifier })

    return (tonumber(changed) or 0) > 0
end

-- Job ------------------------------------------------------------------------

--- ESX has no isBoss flag. Servers signal it through the grade label instead,
--- which is why this checks the conventional names rather than inventing a new
--- config key nobody will remember to fill in.
local BOSS_GRADES = { boss = true, owner = true, chief = true, manager = true }

function impl.getJob(src)
    local p = player(src)
    if not p then return nil end

    local job = p.getJob()

    return Normalize.job(
        job.name, job.label,
        job.grade, job.grade_label or job.grade_name,
        job.onDuty ~= false,   -- Most ESX builds have no duty concept: treat as always on.
        BOSS_GRADES[tostring(job.grade_name or ''):lower()] == true,
        job.salary or job.grade_salary
    )
end

function impl.setJob(src, name, grade)
    local p = player(src)
    if not p then return false end

    p.setJob(name, grade or 0)
    return true
end

--- Only newer ESX builds carry a duty flag. Report the no-op honestly instead of
--- pretending the call worked.
function impl.setDuty(src, duty)
    local p = player(src)
    if not p then return false end

    if p.setJobDuty then
        p.setJobDuty(duty)
        return true
    end

    Debug.log('job', 'setDuty is a no-op on this ESX build (no setJobDuty)')
    return false
end

-- Gang -----------------------------------------------------------------------
-- ESX has no gangs. Config.EsxGangMode decides what to do about that.

function impl.getGang(src)
    local mode = Config.EsxGangMode

    if mode == 'none' then return nil end

    local p = player(src)
    if not p then return nil end

    if mode == 'job' then
        local job = p.getJob()
        return Normalize.gang(job.name, job.label, job.grade,
            job.grade_label or job.grade_name,
            BOSS_GRADES[tostring(job.grade_name or ''):lower()] == true)
    end

    local stored = p.getMeta and p.getMeta(Config.EsxGangMetaKey)
    if type(stored) ~= 'table' then return Normalize.gang() end

    return Normalize.gang(stored.name, stored.label, stored.grade, stored.gradeLabel, stored.isBoss)
end

function impl.setGang(src, name, grade)
    if Config.EsxGangMode ~= 'meta' then
        Debug.log('job', 'setGang ignored - Config.EsxGangMode is %s, not "meta"', tostring(Config.EsxGangMode))
        return false
    end

    local p = player(src)
    if not p or not p.setMeta then return false end

    p.setMeta(Config.EsxGangMetaKey, { name = name, label = name, grade = grade or 0 })
    return true
end

-- Metadata -------------------------------------------------------------------
-- getMeta/setMeta only exist on ESX 1.9+. Older builds get the get/set variable
-- API, which is close enough for what Petals scripts store.

function impl.getMetadata(src, key)
    local p = player(src)
    if not p then return nil end

    if p.getMeta then return p.getMeta(key) end
    return p.get(key)
end

function impl.setMetadata(src, key, value)
    local p = player(src)
    if not p then return false end

    if p.setMeta then
        p.setMeta(key, value)
    else
        p.set(key, value)
    end

    return true
end

-- Permissions ----------------------------------------------------------------

function impl.getGroup(src)
    local p = player(src)
    return p and p.getGroup() or 'user'
end

function impl.isAdmin(src)
    local group = impl.getGroup(src)

    for _, admin in ipairs(Config.AdminGroups) do
        if group == admin then return true end
    end

    return false
end

-- Session ----------------------------------------------------------------------

--- Back to character select. es_extended saves and drops the character on
--- esx:playerLogout, and the select screen (esx_multicharacter, or one built on
--- the bridge) reopens from there. Outside multicharacter mode there is no
--- select screen to return to.
function impl.logout(src)
    if not player(src) then return false end
    if GetResourceState('esx_multicharacter') ~= 'started' and not (core.GetConfig and core.GetConfig().Multichar) then return false end

    TriggerEvent('esx:playerLogout', src)
    return true
end

--- ESX keeps neither death nor cuffs on the player object, so both are recorded
--- from the events at the bottom of this file as they happen.
local dead, cuffed = {}, {}

--- 'dead' or 'cuffed' (ESX has no downed state of its own).
function impl.getCondition(src)
    src = tonumber(src)
    if dead[src] then return 'dead' end
    if cuffed[src] then return 'cuffed' end
    return nil
end

--- ESX Legacy takes (vector, heading) and hands back {x, y, z, heading}; older
--- builds ignore the arguments and return the same table. Either way it is the
--- position ESX will save, which it keeps current while the player moves.
function impl.getPosition(src)
    local p = player(src)
    if not p or not p.getCoords then return nil end

    return Normalize.position(p.getCoords(false, true))
end

-- Employment -------------------------------------------------------------------
-- One job per character in users.job / users.job_grade. ESX has no boss flag;
-- the grade names in BOSS_GRADES count as boss, the same as getJob.

function impl.getJobInfo(name)
    local jobs = core and core.GetJobs and core.GetJobs() or {}
    local job = jobs[name]
    if not job then return nil end

    local grades = {}

    for key, grade in pairs(job.grades or {}) do
        local level = tonumber(grade.grade) or tonumber(key) or 0
        grades[#grades + 1] = Normalize.gradeInfo(level, grade.label or grade.name,
            BOSS_GRADES[tostring(grade.name or ''):lower()] == true, grade.salary)
    end

    return Normalize.jobInfo(name, job.label, grades)
end

function impl.getJobs()
    local list = {}
    for name in pairs(core and core.GetJobs and core.GetJobs() or {}) do list[#list + 1] = impl.getJobInfo(name) end
    return list
end

--- ESX keeps jobs in the database (jobs + job_grades), so this is permanent on
--- its own. Grades are rewritten in one transaction; each keeps its outfits
--- (skin_male / skin_female). There is no boss flag, so a boss rank is named
--- 'boss' - what getJob and getJobInfo read it back as.
function impl.saveJob(name, data)
    local old = {}
    for _, row in ipairs(MySQL.query.await('SELECT grade, name, skin_male, skin_female FROM job_grades WHERE job_name = ?', { name }) or {}) do
        old[tonumber(row.grade)] = row
    end

    local queries = {
        { query = 'INSERT INTO jobs (name, label) VALUES (?, ?) ON DUPLICATE KEY UPDATE label = VALUES(label)', values = { name, data.label } },
        { query = 'DELETE FROM job_grades WHERE job_name = ?', values = { name } },
    }

    for _, g in ipairs(data.grades) do
        local prev = old[g.level] or {}
        local keepName = prev.name and (BOSS_GRADES[prev.name:lower()] == true) == (g.isBoss == true)
        local gradeName = keepName and prev.name
            or (g.isBoss and 'boss')
            or g.label:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')

        if gradeName == '' or (not g.isBoss and BOSS_GRADES[gradeName]) then gradeName = 'rank' .. g.level end

        queries[#queries + 1] = {
            query = 'INSERT INTO job_grades (job_name, grade, name, label, salary, skin_male, skin_female) VALUES (?, ?, ?, ?, ?, ?, ?)',
            values = { name, g.level, gradeName, g.label, g.salary, prev.skin_male or '{}', prev.skin_female or '{}' },
        }
    end

    if not MySQL.transaction.await(queries) then return false end
    if core and core.RefreshJobs then core.RefreshJobs() end
    return true
end

function impl.deleteJob(name)
    local ok = MySQL.transaction.await({
        { query = 'DELETE FROM job_grades WHERE job_name = ?', values = { name } },
        { query = 'DELETE FROM jobs WHERE name = ?', values = { name } },
    })

    if not ok then return false end
    if core and core.RefreshJobs then core.RefreshJobs() end
    return true
end

function impl.getEmployees(job)
    local list, seen = {}, {}

    for _, src in ipairs(core and core.GetPlayers() or {}) do
        local p = player(src)
        local current = p and p.getJob()

        if current and current.name == job then
            local id = p.getIdentifier()
            seen[id] = true
            list[#list + 1] = {
                id = id,
                name = p.getName(),
                grade = tonumber(current.grade) or 0,
                online = src,
                onDuty = current.onDuty ~= false,
            }
        end
    end

    local rows = MySQL.query.await(
        'SELECT identifier, firstname, lastname, job_grade FROM users WHERE job = ?', { job }) or {}

    for _, row in ipairs(rows) do
        if not seen[row.identifier] and not impl.getSource(row.identifier) then
            list[#list + 1] = {
                id = row.identifier,
                name = (('%s %s'):format(row.firstname or '', row.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')),
                grade = tonumber(row.job_grade) or 0,
                online = false,
                onDuty = false,
            }
        end
    end

    return list
end

function impl.setEmployee(id, job, grade)
    local src = impl.getSource(id)
    if src then return impl.setJob(src, job, grade) end

    if not impl.getJobInfo(job) then return false end

    return (MySQL.update.await('UPDATE users SET job = ?, job_grade = ? WHERE identifier = ?', { job, grade, id }) or 0) > 0
end

function impl.removeEmployee(id, job)
    local src = impl.getSource(id)

    if src then
        local current = impl.getJob(src)
        if not current or current.name ~= job then return false end
        return impl.setJob(src, 'unemployed', 0)
    end

    return (MySQL.update.await("UPDATE users SET job = 'unemployed', job_grade = 0 WHERE identifier = ? AND job = ?", { id, job }) or 0) > 0
end

-- Vehicles ---------------------------------------------------------------------

--- 'ABC 123', the shape esx_vehicleshop gives.
local function newPlate()
    local letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

    for _ = 1, 25 do
        local plate = ''
        for _ = 1, 3 do local i = math.random(1, 26) plate = plate .. letters:sub(i, i) end
        plate = ('%s %03d'):format(plate, math.random(0, 999))

        if not MySQL.scalar.await('SELECT 1 FROM owned_vehicles WHERE plate = ? LIMIT 1', { plate }) then
            return plate
        end
    end

    return nil
end

--- owned_vehicles differs between ESX builds: `type` and `parking` (the garage
--- name esx_garage reads) are not on every one. Looked up once.
local vehicleColumns

local function hasVehicleColumn(column)
    if not vehicleColumns then
        vehicleColumns = {}

        local rows = MySQL.query.await([[
            SELECT COLUMN_NAME AS name FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'owned_vehicles'
        ]]) or {}

        for _, row in ipairs(rows) do vehicleColumns[row.name] = true end
    end

    return vehicleColumns[column] == true
end

--- An owned car, stored (stored = 1) in `garage`.
function impl.giveVehicle(src, model, garage)
    local p = player(src)
    if not p then return nil end

    local plate = newPlate()
    if not plate then return nil end

    local columns = { 'owner', 'plate', 'vehicle', 'stored' }
    local values = { p.getIdentifier(), plate, json.encode({ model = joaat(model), plate = plate }), 1 }

    if hasVehicleColumn('type') then columns[#columns + 1] = 'type'; values[#values + 1] = 'car' end
    if hasVehicleColumn('parking') then columns[#columns + 1] = 'parking'; values[#values + 1] = garage end

    MySQL.insert.await(('INSERT INTO owned_vehicles (%s) VALUES (%s)'):format(
        table.concat(columns, ', '), ('?'):rep(#columns, ', ')), values)

    return plate
end

--- The vehicles table (esx_vehicleshop), by model name and hash. Read once.
local vehicleNames

local function esxVehicles()
    if not vehicleNames then
        vehicleNames = {}
        local ok, rows = pcall(MySQL.query.await, 'SELECT model, name FROM vehicles')

        for _, row in ipairs(ok and rows or {}) do
            local entry = { model = row.model, label = row.name or row.model }
            for _, hash in ipairs(Normalize.hashes(GetHashKey(row.model))) do vehicleNames[hash] = entry end
            vehicleNames[row.model] = entry
        end
    end

    return vehicleNames
end

--- Every row of ESX's vehicles table. It has no category, so everything lands
--- under 'other' and the dealership's own config decides what each shop sells.
function impl.getVehicleCatalogue()
    local ok, rows = pcall(MySQL.query.await, 'SELECT model, name, price, category FROM vehicles')
    if not ok then
        ok, rows = pcall(MySQL.query.await, 'SELECT model, name, price FROM vehicles')
    end

    local out = {}

    for _, row in ipairs(ok and rows or {}) do
        out[#out + 1] = {
            model = row.model,
            name = row.name or row.model,
            brand = '',
            label = row.name or row.model,
            price = math.floor(tonumber(row.price) or 0),
            category = row.category or 'other',
            kind = 'automobile',
        }
    end

    return out
end

--- { model, label } from the vehicles table, or nil.
function impl.getVehicleName(model)
    local names = esxVehicles()
    if type(model) == 'string' then return names[model] end

    for _, hash in ipairs(Normalize.hashes(model)) do
        if names[hash] then return names[hash] end
    end
end

--- Every owned vehicle (for logs watching ownership and garages). ESX keeps the
--- model inside the saved properties, and a garage name only when the
--- owned_vehicles table has a parking column.
function impl.getOwnedVehicles()
    local parking = hasVehicleColumn('parking')
    local query = parking and 'SELECT plate, owner, vehicle, stored, parking FROM owned_vehicles'
        or 'SELECT plate, owner, vehicle, stored FROM owned_vehicles'

    local list = {}

    for _, row in ipairs(MySQL.query.await(query) or {}) do
        local ok, props = pcall(json.decode, row.vehicle or '')
        local hash = ok and type(props) == 'table' and props.model or nil
        local name = hash and impl.getVehicleName(hash)

        list[#list + 1] = {
            key = row.plate, plate = row.plate, owner = row.owner,
            model = name and name.model or tostring(hash or '?'),
            garage = parking and row.parking or nil,
            state = (tonumber(row.stored) == 1 or row.stored == true) and 'garaged' or 'out',
        }
    end

    return list
end

--- The identifier that owns a plate, or nil. ESX keeps the plate as the
--- vehicle showed it, spaces inside included.
function impl.getVehicleOwner(plate)
    return MySQL.scalar.await('SELECT owner FROM owned_vehicles WHERE plate = ? OR TRIM(plate) = ? LIMIT 1', { plate, plate })
end

--- ESX keeps everything about a car - model, mods, fuel, damage - inside the
--- `vehicle` JSON, with only `stored` and (on most builds) `parking` beside it.
--- There is no impound column: an impounded car is simply not stored, and the
--- garage script keeps the reason and the release time in its own table.
local function esxShape(row, parking)
    local ok, props = pcall(json.decode, row.vehicle or '')
    props = (ok and type(props) == 'table') and props or nil

    local name = props and props.model and impl.getVehicleName(props.model)

    return {
        key = row.plate,
        plate = row.plate,
        owner = row.owner,
        model = name and name.model or (props and tostring(props.model) or '?'),
        garage = parking and row.parking or nil,
        state = (tonumber(row.stored) == 1 or row.stored == true) and 'garaged' or 'out',
        props = props,
        fuel = props and tonumber(props.fuelLevel) or nil,
        engine = props and tonumber(props.engineHealth) or nil,
        body = props and tonumber(props.bodyHealth) or nil,
        depot = 0,
    }
end

function impl.getCharacterVehicles(identifier)
    local parking = hasVehicleColumn('parking')
    local query = parking and 'SELECT plate, owner, vehicle, stored, parking FROM owned_vehicles WHERE owner = ?'
        or 'SELECT plate, owner, vehicle, stored FROM owned_vehicles WHERE owner = ?'

    local list = {}
    for _, row in ipairs(MySQL.query.await(query, { identifier }) or {}) do
        list[#list + 1] = esxShape(row, parking)
    end

    return list
end

function impl.getVehicle(plate)
    local parking = hasVehicleColumn('parking')
    local query = parking and 'SELECT plate, owner, vehicle, stored, parking FROM owned_vehicles WHERE plate = ? OR TRIM(plate) = ? LIMIT 1'
        or 'SELECT plate, owner, vehicle, stored FROM owned_vehicles WHERE plate = ? OR TRIM(plate) = ? LIMIT 1'

    local row = MySQL.single.await(query, { plate, plate })
    return row and esxShape(row, parking) or nil
end

--- Saves what ESX can hold. Fuel, engine and body have no columns of their
--- own, so they go into the properties; when the caller gives both, the
--- explicit value wins.
function impl.saveVehicle(plate, data)
    local crumbs, values = {}, {}

    local props = type(data.props) == 'table' and data.props or nil

    if props then
        local merged = {}
        for k, v in pairs(props) do merged[k] = v end
        if data.fuel then merged.fuelLevel = data.fuel end
        if data.engine then merged.engineHealth = data.engine end
        if data.body then merged.bodyHealth = data.body end

        crumbs[#crumbs + 1] = 'vehicle = ?'
        values[#values + 1] = json.encode(merged)
    elseif data.fuel or data.engine or data.body then
        -- Nothing to merge into without a read first.
        local current = impl.getVehicle(plate)
        local merged = current and current.props or {}
        if data.fuel then merged.fuelLevel = data.fuel end
        if data.engine then merged.engineHealth = data.engine end
        if data.body then merged.bodyHealth = data.body end

        crumbs[#crumbs + 1] = 'vehicle = ?'
        values[#values + 1] = json.encode(merged)
    end

    if data.state ~= nil then
        crumbs[#crumbs + 1] = 'stored = ?'
        values[#values + 1] = Normalize.vehicleStateId(data.state) == 1 and 1 or 0
    end

    if data.garage ~= nil and hasVehicleColumn('parking') then
        crumbs[#crumbs + 1] = 'parking = ?'
        values[#values + 1] = data.garage
    end

    if #crumbs == 0 then return false end

    values[#values + 1] = plate
    values[#values + 1] = plate

    local affected = MySQL.update.await(
        ('UPDATE owned_vehicles SET %s WHERE plate = ? OR TRIM(plate) = ?'):format(table.concat(crumbs, ', ')), values)

    return (affected or 0) > 0
end

--- Deletes an owned vehicle outright (sold back, scrapped).
function impl.deleteVehicle(plate)
    local affected = MySQL.update.await(
        'DELETE FROM owned_vehicles WHERE plate = ? OR TRIM(plate) = ?', { plate, plate })

    return (affected or 0) > 0
end

--- ESX has no gangs of its own. With Config.EsxGangMode = 'job' a gang is the
--- job, so the jobs stand in; otherwise there are none to list.
function impl.getGangInfo(name)
    if Config.EsxGangMode ~= 'job' then return nil end
    return impl.getJobInfo(name)
end

function impl.getGangs()
    if Config.EsxGangMode ~= 'job' then return {} end
    return impl.getJobs()
end

--- Signs a vehicle over to another character.
function impl.setVehicleOwner(plate, identifier)
    local affected = MySQL.update.await(
        'UPDATE owned_vehicles SET owner = ? WHERE plate = ? OR TRIM(plate) = ?', { identifier, plate, plate })

    return (affected or 0) > 0
end

-- Items ------------------------------------------------------------------------
-- Used when ox_inventory is not running (bridge/server/items.lua goes to it
-- directly when it is): ESX's own inventory on the player object.

function impl.getItemCount(src, item)
    local p = player(src)
    local found = p and p.getInventoryItem(item)
    return found and found.count or 0
end

function impl.removeItem(src, item, count)
    local p = player(src)
    if not p then return false end
    if impl.getItemCount(src, item) < count then return false end
    p.removeInventoryItem(item, count)
    return true
end

--- ESX items carry no metadata, so every copy looks the same.
function impl.getItems(src, item)
    local count = impl.getItemCount(src, item)
    return count > 0 and { { count = count } } or {}
end

function impl.giveItem(src, item, count, metadata)
    local p = player(src)
    if not p then return false end

    p.addInventoryItem(item, count, metadata)
    return true
end

--- ESX items carry no metadata to change.
function impl.setItemMetadata() return false end

function impl.removeItemSlot(src, item)
    return impl.removeItem(src, item, 1)
end

--- ESX reads its items from the items table, so a missing one is inserted.
--- ESX only loads that table on start: the new items work after a restart.
function impl.ensureItems(defs)
    local added = {}
    for _, def in ipairs(defs) do
        local affected = MySQL.update.await('INSERT IGNORE INTO items (name, label, weight) VALUES (?, ?, ?)',
            { def.name, def.label, math.floor((def.weight or 0) / 1000 + 0.5) })
        if (affected or 0) > 0 then added[#added + 1] = def.name end
    end
    return added
end

function impl.registerUsableItem(item, cb)
    if not core then return false end
    core.RegisterUsableItem(item, function(source) cb(source, { name = item }) end)
    return true
end

-- Characters -------------------------------------------------------------------
-- For a character select screen that replaces esx_multicharacter. es_extended
-- must run in multicharacter mode: set Config.Multichar = true in
-- es_extended/shared/config/main.lua (it only turns itself on when a resource
-- named esx_multicharacter exists).
--
-- A character is a users row whose identifier is "<prefix><slot>:<license>".

local function prefix()
    return Config.EsxCharacterPrefix or 'char'
end

--- The "<prefix><slot>:" part is stripped, the rest must be this player's.
---@return number|nil slot
local function slotOf(src, identifier)
    if not core or type(identifier) ~= 'string' then return nil end

    local p = prefix()
    local slot, rest = identifier:match('^' .. p:gsub('%p', '%%%0') .. '(%d+):(.+)$')
    if not slot or rest ~= core.GetIdentifier(src) then return nil end

    return tonumber(slot)
end

local function multicharReady()
    if not core then return false end

    local config = core.GetConfig and core.GetConfig() or {}
    if config.Multichar then return true end

    Debug.err('es_extended is not in multicharacter mode. Set Config.Multichar = true in es_extended/shared/config/main.lua.')
    return false
end

--- 'YYYY-MM-DD' into Config.EsxDateFormat, which is how esx_identity stores it.
local function esxDate(iso)
    local y, m, d = tostring(iso):match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
    if not y then return iso end

    return ((Config.EsxDateFormat or 'DD/MM/YYYY'):gsub('YYYY', y):gsub('MM', m):gsub('DD', d))
end

local function jobLabels(name, grade)
    local jobs = core.GetJobs and core.GetJobs() or {}
    local job = jobs[name]
    if not job then return name, '' end

    local g = job.grades and job.grades[tostring(grade)]
    return job.label or name, (name ~= 'unemployed' and g and g.label) or ''
end

--- Wait for es_extended to finish building the xPlayer, which it does after a
--- database round trip.
local function awaitPlayer(src)
    local deadline = GetGameTimer() + 15000
    while not player(src) do
        if GetGameTimer() > deadline or GetPlayerPing(src) == 0 then return false end
        Wait(50)
    end
    return true
end

function impl.getCharacters(src)
    if not core then return {} end

    local rows = MySQL.query.await(
        'SELECT identifier, accounts, job, job_grade, firstname, lastname, dateofbirth, sex, position FROM users WHERE identifier LIKE ?',
        { ('%s%%:%s'):format(prefix(), core.GetIdentifier(src)) }) or {}

    local list = {}
    for _, row in ipairs(rows) do
        local slot = slotOf(src, row.identifier)
        if slot then
            local accounts = Normalize.json(row.accounts)
            local job, grade = jobLabels(row.job, row.job_grade)

            list[#list + 1] = Normalize.character({
                id = row.identifier, slot = slot,
                firstname = row.firstname, lastname = row.lastname, birthdate = row.dateofbirth,
                gender = row.sex, job = job, grade = grade,
                cash = accounts.money, bank = accounts.bank,
                position = Normalize.json(row.position),
            })
        end
    end

    table.sort(list, function(a, b) return a.slot < b.slot end)
    return list
end

--- skinchanger's format, or illenium-appearance's when that is installed. The
--- model comes from the skin when it names one, otherwise from the sex.
function impl.getAppearance(src, identifier)
    if not slotOf(src, identifier) then return nil end

    local row = MySQL.single.await('SELECT skin, sex FROM users WHERE identifier = ?', { identifier })
    if not row then return nil end

    local skin = Normalize.json(row.skin)
    local female = skin.sex == 1 or (skin.sex == nil and tostring(row.sex):lower():sub(1, 1) == 'f')

    return { model = skin.model or (female and 'mp_f_freemode_01' or 'mp_m_freemode_01'), skin = skin }
end

function impl.loadCharacter(src, identifier)
    local slot = slotOf(src, identifier)
    if not slot or player(src) or not multicharReady() then return false end

    -- The same account already playing this character from another connection.
    if core.GetPlayerFromIdentifier(identifier) then return false end
    if not MySQL.scalar.await('SELECT 1 FROM users WHERE identifier = ?', { identifier }) then return false end

    TriggerEvent('esx:onPlayerJoined', src, prefix() .. slot)
    return awaitPlayer(src)
end

--- data: { firstname, lastname, birthdate = 'YYYY-MM-DD', gender = 0|1, height }
function impl.createCharacter(src, data, slot)
    slot = math.floor(tonumber(slot) or 0)
    if not core or slot < 1 or player(src) or not multicharReady() then return nil end

    local identifier = ('%s%d:%s'):format(prefix(), slot, core.GetIdentifier(src))
    if MySQL.scalar.await('SELECT 1 FROM users WHERE identifier = ?', { identifier }) then return nil end

    TriggerEvent('esx:onPlayerJoined', src, prefix() .. slot, {
        firstname = data.firstname,
        lastname = data.lastname,
        dateofbirth = esxDate(data.birthdate),
        sex = data.gender == 1 and 'f' or 'm',
        height = math.floor(tonumber(data.height) or 180),
    })

    return awaitPlayer(src) and identifier or nil
end

--- Every table with an identifier or owner column holds rows keyed the same way
--- (vehicles, licenses, billing...), so all of them are cleared, like
--- esx_multicharacter does.
local ownedTables

function impl.deleteCharacter(src, identifier)
    if not slotOf(src, identifier) or core.GetPlayerFromIdentifier(identifier) then return false end

    ownedTables = ownedTables or MySQL.query.await(
        "SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_NAME IN ('identifier', 'owner')") or {}

    local queries = {}
    for _, column in ipairs(ownedTables) do
        queries[#queries + 1] = {
            query = ('DELETE FROM `%s` WHERE `%s` = ?'):format(column.TABLE_NAME, column.COLUMN_NAME),
            values = { identifier },
        }
    end

    if #queries == 0 then
        queries[1] = { query = 'DELETE FROM users WHERE identifier = ?', values = { identifier } }
    end

    return MySQL.transaction.await(queries) and true or false
end

if not Bridge.register(FW, impl) then return end

-- Player load state -------------------------------------------------------------

AddEventHandler('esx:playerLoaded', function(src)
    Bridge.setLoaded(src, true)
end)

-- Sent by esx_multicharacter when a player goes back to character select.
AddEventHandler('esx:playerLogout', function(src)
    Bridge.setLoaded(src, false)
end)

-- Job, duty and money changes -----------------------------------------------------
-- ESX fires these from xPlayer.setJob and the account functions (Legacy 1.9+).

AddEventHandler('esx:setJob', function(src) Bridge.jobUpdated(src) end)

AddEventHandler('esx:addAccountMoney', function(src, account, amount, reason)
    Bridge.moneyChanged(src, account, amount, 'add', reason)
end)

AddEventHandler('esx:removeAccountMoney', function(src, account, amount, reason)
    Bridge.moneyChanged(src, account, amount, 'remove', reason)
end)

AddEventHandler('esx:setAccountMoney', function(src, account, amount, reason)
    Bridge.moneyChanged(src, account, amount, 'set', reason)
end)

-- Death and cuffs (read by getCondition) --------------------------------------------
-- es_extended reports its own deaths and respawns, esx_ambulancejob its death
-- status, and esx_policejob toggles cuffs through a server event an officer
-- sends. A player can only mark themselves dead; cuffs count only from police.

RegisterNetEvent('esx:onPlayerDeath', function() dead[source] = true end)
RegisterNetEvent('esx:onPlayerSpawn', function() dead[source] = nil end)

RegisterNetEvent('esx_ambulancejob:setDeathStatus', function(isDead)
    dead[source] = isDead and true or nil
end)

RegisterNetEvent('esx_policejob:handcuff', function(target)
    target = tonumber(target)
    local job = impl.getJob(source)
    if not target or not job or job.name ~= 'police' then return end

    cuffed[target] = not cuffed[target] or nil
end)

AddEventHandler('playerDropped', function()
    dead[source], cuffed[source] = nil, nil
end)
