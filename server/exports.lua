---@diagnostic disable: lowercase-global
--- The public server surface.
---
--- Consumers never see the Bridge table itself - they get these exports, wrapped
--- into a Bridge-shaped table by init.lua. Keeping the boundary here means a
--- framework file can change shape without breaking a single Petals script.

local call = Bridge.call

-- Identity -------------------------------------------------------------------

exports('getIdentifier', function(src) return call('getIdentifier', src) end)
exports('getIdentity', function(src) return call('getIdentity', src) end)
exports('getName', function(src) return call('getName', src) end)
exports('getSource', function(identifier) return call('getSource', identifier) end)
exports('getOnlinePlayers', function() return call('getOnlinePlayers') end)
exports('getOfflineName', function(identifier) return call('getOfflineName', identifier) end)

--- The raw framework player object, for the rare case a script genuinely needs
--- something the bridge does not cover. Using this ties that script to one
--- framework, so it is a deliberate escape hatch, not a convenience.
exports('getPlayer', function(src) return call('getPlayer', src) end)

-- Money ----------------------------------------------------------------------

exports('getMoney', function(src, account)
    return call('getMoney', src, account or 'cash') or 0
end)

exports('addMoney', function(src, account, amount, reason)
    if type(amount) ~= 'number' or amount <= 0 then
        Debug.err('addMoney called with a non-positive amount (%s)', tostring(amount))
        return false
    end

    Debug.log('money', 'addMoney %s %s %s (%s)', src, amount, account, reason or 'no reason')
    return call('addMoney', src, account or 'cash', amount, reason or 'petals_bridge') or false
end)

--- allowNegative: a bank account may go below zero (bills, fines). Cash never
--- does. QB-Core and Qbox decide this themselves (their dontAllowMinus list,
--- which lets bank go negative by default); ESX follows the flag.
exports('removeMoney', function(src, account, amount, reason, allowNegative)
    if type(amount) ~= 'number' or amount <= 0 then
        Debug.err('removeMoney called with a non-positive amount (%s)', tostring(amount))
        return false
    end

    Debug.log('money', 'removeMoney %s %s %s (%s)', src, amount, account, reason or 'no reason')
    return call('removeMoney', src, account or 'cash', amount, reason or 'petals_bridge', allowNegative == true) or false
end)

--- Pay a character by identifier, in the city or not. In the city this is
--- addMoney. Otherwise it goes straight into what the framework saved, and
--- they have it the next time they play.
exports('addMoneyByIdentifier', function(identifier, account, amount, reason)
    if type(identifier) ~= 'string' or identifier == '' then return false end
    if type(amount) ~= 'number' or amount <= 0 then
        Debug.err('addMoneyByIdentifier called with a non-positive amount (%s)', tostring(amount))
        return false
    end

    local src = call('getSource', identifier)
    if src and GetPlayerName(src) then
        return call('addMoney', src, account or 'cash', amount, reason or 'petals_bridge') or false
    end

    Debug.log('money', 'addMoneyByIdentifier %s %s %s offline (%s)', identifier, amount, account, reason or 'no reason')
    return call('addOfflineMoney', identifier, account or 'cash', math.floor(amount)) or false
end)

--- Charge a player from cash, falling back to bank.
---
--- Every Petals script that sells something needs this and each one used to
--- reimplement it slightly differently. The split matters: taking the whole
--- amount from bank when the player has most of it in cash is the kind of thing
--- players open tickets about.
exports('chargePlayer', function(src, amount, reason)
    if type(amount) ~= 'number' or amount <= 0 then return false end

    local cash = call('getMoney', src, 'cash') or 0

    if cash >= amount then
        return call('removeMoney', src, 'cash', amount, reason or 'petals_bridge') or false
    end

    local bank = call('getMoney', src, 'bank') or 0
    if cash + bank < amount then return false end

    -- Drain cash first, then take the remainder from bank. Done in this order so
    -- a failure on the second leg leaves the smaller hole.
    if cash > 0 and not call('removeMoney', src, 'cash', cash, reason or 'petals_bridge') then
        return false
    end

    return call('removeMoney', src, 'bank', amount - cash, reason or 'petals_bridge') or false
end)

-- Job ------------------------------------------------------------------------

exports('getJob', function(src) return call('getJob', src) end)

exports('setJob', function(src, name, grade)
    Debug.log('job', 'setJob %s -> %s[%s]', src, name, grade or 0)
    return call('setJob', src, name, grade) or false
end)

exports('setDuty', function(src, duty) return call('setDuty', src, duty == true) or false end)

exports('getDuty', function(src)
    local job = call('getJob', src)
    return job and job.onDuty or false
end)

--- Convenience used constantly by job scripts: one call instead of fetching the
--- job table and comparing two fields.
exports('hasJob', function(src, name, minGrade)
    local job = call('getJob', src)
    if not job or job.name ~= name then return false end

    return job.grade >= (minGrade or 0)
end)

exports('isBoss', function(src)
    local job = call('getJob', src)
    return job and job.isBoss or false
end)

-- Gang -----------------------------------------------------------------------

exports('getGang', function(src) return call('getGang', src) end)
exports('setGang', function(src, name, grade) return call('setGang', src, name, grade) or false end)

exports('hasGang', function(src, name, minGrade)
    local gang = call('getGang', src)
    if not gang or gang.name ~= name then return false end

    return gang.grade >= (minGrade or 0)
end)

-- Metadata -------------------------------------------------------------------

exports('getMetadata', function(src, key) return call('getMetadata', src, key) end)
exports('setMetadata', function(src, key, value) return call('setMetadata', src, key, value) or false end)

-- Permissions ----------------------------------------------------------------

exports('getGroup', function(src) return call('getGroup', src) end)
exports('isAdmin', function(src) return call('isAdmin', src) or false end)

-- Session ----------------------------------------------------------------------

exports('logout', function(src) return call('logout', src) or false end)

--- The character's saved position as a vector4, or nil when there is none.
exports('getPosition', function(src) return call('getPosition', src) end)

--- 'dead', 'downed' or 'cuffed', or nil when none of those. The framework's
--- own record first (medical and police metadata), then what any server can
--- see: an isDead state bag (qbx_medical and most ambulance scripts set one),
--- or a ped with no health left.
exports('getCondition', function(src)
    local condition = call('getCondition', src)
    if condition then return condition end

    local player = Player(src)
    if player and player.state and player.state.isDead then return 'dead' end

    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 and GetEntityHealth(ped) <= 0 then return 'dead' end

    return nil
end)

--- 'male' or 'female' from the character's identity, or nil when the framework
--- has none on record (callers usually fall back to the ped model).
exports('getGender', function(src)
    local id = call('getIdentity', src)
    return id and Normalize.gender(id.gender) or nil
end)

-- Employment -------------------------------------------------------------------
-- For boss menus: whole jobs, and characters whether they are online or not.
-- `id` is the character's identifier (citizenid on QB/Qbox, identifier on ESX).

--- A job and its grades (lowest first), or nil if the job does not exist.
exports('getJobInfo', function(name)
    if type(name) ~= 'string' then return nil end
    return call('getJobInfo', name)
end)

--- Everyone holding the job: { id, name, grade, online = server id | false, onDuty }.
exports('getEmployees', function(job)
    if type(job) ~= 'string' then return {} end
    return call('getEmployees', job) or {}
end)

--- Give a character the job at `grade`, or change their grade in it. Works
--- online or offline. False if the job or grade does not exist.
exports('setEmployee', function(id, job, grade)
    grade = tonumber(grade)
    if type(id) ~= 'string' or type(job) ~= 'string' or not grade then return false end

    local info = call('getJobInfo', job)
    if not info then return false end

    local exists = false
    for _, g in ipairs(info.grades) do if g.level == grade then exists = true end end
    if not exists then return false end

    Debug.log('job', 'setEmployee %s -> %s[%s]', id, job, grade)
    return call('setEmployee', id, job, grade) == true
end)

--- Take a character out of the job (back to unemployed when it was their main one).
exports('removeEmployee', function(id, job)
    if type(id) ~= 'string' or type(job) ~= 'string' then return false end

    Debug.log('job', 'removeEmployee %s from %s', id, job)
    return call('removeEmployee', id, job) == true
end)

-- Jobs -------------------------------------------------------------------------
-- For job creators: make, change and remove jobs while the server runs. On QB
-- and Qbox this is live only (their jobs.lua is never written), so the caller
-- keeps its own copy and saves it again on every start. ESX's is permanent.

--- Every job, as getJobInfo tables.
exports('getJobs', function() return call('getJobs') or {} end)

--- A gang and its grades (lowest first) in the getJobInfo shape, or nil. ESX
--- has none unless Config.EsxGangMode = 'job', where the jobs stand in.
exports('getGangInfo', function(name)
    if type(name) ~= 'string' then return nil end
    return call('getGangInfo', name)
end)

--- Every gang, as getGangInfo tables.
exports('getGangs', function() return call('getGangs') or {} end)

local function text(value, max)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    return value ~= '' and #value <= max and value or nil
end

--- The job as saveJob takes it, cleaned, or nil and why not.
local function cleanJob(name, data)
    if type(name) ~= 'string' or not name:match('^[a-z0-9_]+$') or #name > 50 then return nil, 'name' end
    if type(data) ~= 'table' or type(data.grades) ~= 'table' then return nil, 'data' end

    local job = {
        label = text(data.label, 50),
        type = data.type ~= nil and data.type ~= '' and text(data.type, 20) or nil,
        defaultDuty = data.defaultDuty ~= false,
        offDutyPay = data.offDutyPay == true,
        grades = {},
    }

    if not job.label then return nil, 'label' end
    if data.type ~= nil and data.type ~= '' and not (job.type and job.type:match('^[%w_]+$')) then return nil, 'type' end
    if #data.grades < 1 or #data.grades > 30 then return nil, 'grades' end

    local seen = {}
    for _, g in ipairs(data.grades) do
        local level, salary = tonumber(type(g) == 'table' and g.level), tonumber(type(g) == 'table' and g.salary or 0)
        local label = type(g) == 'table' and text(g.label, 50)

        if not level or level < 0 or level > 99 or level % 1 ~= 0 or seen[level] then return nil, 'grades' end
        if not label or not salary or salary < 0 or salary % 1 ~= 0 then return nil, 'grades' end

        seen[level] = true
        job.grades[#job.grades + 1] = { level = level, label = label, salary = salary, isBoss = g.isBoss == true }
    end

    table.sort(job.grades, function(a, b) return a.level < b.level end)
    return job
end

--- Create a job, or change one (it is replaced whole: label, flags, grades).
--- data: { label, type?, defaultDuty?, offDutyPay?, grades = { level, label,
--- salary, isBoss }[] }. Nobody's grade is moved - do that first if a grade
--- someone holds is going away.
exports('saveJob', function(name, data)
    local job, why = cleanJob(name, data)
    if not job then Debug.err('saveJob %s refused: bad %s', tostring(name), why) return false end

    Debug.log('job', 'saveJob %s (%d grades)', name, #job.grades)
    return call('saveJob', name, job) == true
end)

--- Remove a job. Everyone holding it is taken out of it first (back to
--- unemployed where it was their main job). 'unemployed' itself cannot go.
exports('deleteJob', function(name)
    if type(name) ~= 'string' or name == 'unemployed' or not call('getJobInfo', name) then return false end

    for _, e in ipairs(call('getEmployees', name) or {}) do call('removeEmployee', e.id, name) end

    Debug.log('job', 'deleteJob %s', name)
    return call('deleteJob', name) == true
end)

-- Society money ------------------------------------------------------------------

--- Give the job an (empty) society account if it has none. False when the
--- banking resource cannot open one while the server runs.
exports('ensureSocietyAccount', function(job, label)
    if type(job) ~= 'string' then return false end
    return Society.ensure(job, type(label) == 'string' and label or job)
end)

--- The job's account balance, or nil when there is no banking resource or account.
exports('getSocietyMoney', function(job)
    if type(job) ~= 'string' then return nil end
    return Society.balance(job)
end)

local function wholeAmount(amount)
    amount = tonumber(amount)
    return amount and amount > 0 and math.floor(amount) == amount and amount or nil
end

exports('addSocietyMoney', function(job, amount, reason)
    amount = wholeAmount(amount)
    if type(job) ~= 'string' or not amount then return false end

    Debug.log('money', 'society %s +%d (%s)', job, amount, tostring(reason))
    return Society.add(job, amount, reason)
end)

exports('removeSocietyMoney', function(job, amount, reason)
    amount = wholeAmount(amount)
    if type(job) ~= 'string' or not amount then return false end

    Debug.log('money', 'society %s -%d (%s)', job, amount, tostring(reason))
    return Society.remove(job, amount, reason)
end)

-- Vehicles ---------------------------------------------------------------------

--- Gives the loaded character an owned vehicle, parked in `garage` - the name
--- your garage script uses for it. Returns the plate, or nil if it could not.
exports('giveVehicle', function(src, model, garage)
    if type(model) ~= 'string' or model == '' then return nil end
    return call('giveVehicle', src, model, garage)
end)

--- Keys to a vehicle (an entity) through the keys resource the server runs
--- (Config.VehicleKeys). True when given, or when there is no keys resource.
exports('giveKeys', function(src, vehicle)
    if not tonumber(src) or not vehicle or not DoesEntityExist(vehicle) then return false end
    return Keys.give(tonumber(src), vehicle)
end)

exports('removeKeys', function(src, vehicle)
    if not tonumber(src) or not vehicle or not DoesEntityExist(vehicle) then return false end
    return Keys.remove(tonumber(src), vehicle)
end)

--- The identifier (as Bridge.getIdentifier gives it) of the character owning a
--- plate, or nil for a plate nobody owns. Leading and trailing spaces are
--- ignored; GTA pads plates to eight characters.
exports('getVehicleOwner', function(plate)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return nil end
    return call('getVehicleOwner', plate)
end)

--- Every owned vehicle: { key, plate, owner, model, garage, state = 'out' |
--- 'garaged' | 'impound' }. One query over the whole table - for a logger that
--- compares it now and then, not for anything per frame.
exports('getOwnedVehicles', function() return call('getOwnedVehicles') or {} end)

--- Every vehicle the framework can sell: { model, name, brand, label, price,
--- category, kind }. Ask once and keep it - it is hundreds of rows.
exports('getVehicleCatalogue', function() return call('getVehicleCatalogue') or {} end)

--- { model, label } for a model name or hash, from the framework's vehicle list.
exports('getVehicleName', function(model)
    if type(model) ~= 'string' and type(model) ~= 'number' then return nil end
    return call('getVehicleName', model)
end)

--- Every vehicle one character owns, for a garage to list:
--- { key, plate, owner, model, garage, state, props, fuel, engine, body, depot }.
--- `props` are the saved vehicle properties (ox_lib shape on Qbox, whatever the
--- framework wrote otherwise) or nil for a car that has never been saved.
exports('getCharacterVehicles', function(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return {} end
    return call('getCharacterVehicles', identifier) or {}
end)

--- One owned vehicle by plate, in the same shape, or nil.
exports('getVehicle', function(plate)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return nil end
    return call('getVehicle', plate)
end)

--- Saves an owned vehicle: `{ garage, state, props, fuel, engine, body, depot,
--- coords }`. Anything left out is left as it was, so fuel can be saved without
--- touching the garage. `state` is 'out' | 'garaged' | 'impound'. True when a
--- row changed.
---
--- ESX has no impound column, so an impounded car there is stored = 0; keep the
--- reason and the release time in your own table.
--- Signs an owned vehicle over to another character (a garage transfer, a
--- dealership sale). True when a row changed.
exports('setVehicleOwner', function(plate, identifier)
    if type(plate) ~= 'string' or type(identifier) ~= 'string' or identifier == '' then return false end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return false end
    return call('setVehicleOwner', plate, identifier) or false
end)

--- Deletes an owned vehicle outright - sold back to a dealership, or scrapped.
--- Every garage stops listing it. True when a row went.
exports('deleteVehicle', function(plate)
    if type(plate) ~= 'string' then return false end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return false end
    return call('deleteVehicle', plate) == true
end)

exports('saveVehicle', function(plate, data)
    if type(plate) ~= 'string' or type(data) ~= 'table' then return false end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return false end
    return call('saveVehicle', plate, data) or false
end)

-- Items ------------------------------------------------------------------------
-- ox_inventory when it runs, otherwise the framework's own inventory
-- (bridge/server/items.lua).

--- How many of an item a player carries.
exports('getItemCount', function(src, item)
    if not tonumber(src) or type(item) ~= 'string' then return 0 end
    return Items.count(tonumber(src), item)
end)

exports('hasItem', function(src, item, count)
    if not tonumber(src) or type(item) ~= 'string' then return false end
    return Items.count(tonumber(src), item) >= (tonumber(count) or 1)
end)

--- Takes `count` (default 1). False when the player had too few.
exports('removeItem', function(src, item, count)
    count = math.floor(tonumber(count) or 1)
    if not tonumber(src) or type(item) ~= 'string' or count < 1 then return false end
    return Items.remove(tonumber(src), item, count)
end)

--- Every stack of an item a player carries, as { count, slot, metadata }. Empty when
--- they have none. Inventories without metadata answer with one plain stack.
exports('getItems', function(src, item)
    if not tonumber(src) or type(item) ~= 'string' then return {} end
    return Items.search(tonumber(src), item)
end)

--- Gives `count` (default 1) of an item, with optional metadata. False when
--- the inventory refused it - a full bag, or an item that does not exist.
exports('giveItem', function(src, item, count, metadata)
    count = math.floor(tonumber(count) or 1)
    if not tonumber(src) or type(item) ~= 'string' or count < 1 then return false end

    return Items.give(tonumber(src), item, count, type(metadata) == 'table' and metadata or nil)
end)

--- Replaces the metadata of the item in one slot (from getItems). False where
--- the inventory keeps no metadata.
exports('setItemMetadata', function(src, slot, metadata)
    if not tonumber(src) or not tonumber(slot) or type(metadata) ~= 'table' then return false end
    return Items.setMetadata(tonumber(src), tonumber(slot), metadata)
end)

--- Takes one of an item out of one slot.
exports('removeItemSlot', function(src, item, slot)
    if not tonumber(src) or type(item) ~= 'string' or not tonumber(slot) then return false end
    return Items.removeSlot(tonumber(src), item, tonumber(slot))
end)

--- Adds items the inventory does not know yet, so a resource works without
--- anybody editing an item list. See bridge/server/items.lua.
exports('ensureItems', function(defs)
    return Items.ensure(defs, GetInvokingResource() or 'unknown')
end)

--- cb(src, item) runs whenever a player uses the item, from any inventory.
--- item is { name, slot, metadata } - slot and metadata where the inventory
--- has them. Register an item once; a later registration of the same name replaces this one.
exports('registerUsableItem', function(item, cb)
    if type(item) ~= 'string' or cb == nil then return false end
    return call('registerUsableItem', item, cb) == true
end)

-- Logging ------------------------------------------------------------------------

--- Hands an action to whatever logs them (petals_logs listens). Scripts call it
--- without depending on a logger: with nothing listening, nothing happens.
---   kind     'staff' | 'job' | anything the logger routes on
---   src      who did it (server id), or 0 for the server
---   action   one line, e.g. 'Created job Burger Shot'
---   details  optional { { name = ..., value = ... }, ... } shown as fields
exports('log', function(kind, src, action, details)
    if type(kind) ~= 'string' or type(action) ~= 'string' then return end

    TriggerEvent('petals_bridge:log', {
        kind = kind,
        resource = GetInvokingResource() or GetCurrentResourceName(),
        source = tonumber(src) or 0,
        action = action,
        details = type(details) == 'table' and details or {},
    })
end)

-- Characters ---------------------------------------------------------------------
-- For a character select screen. None of these check slot limits or validate
-- names: that is the screen's job, before it calls them.

--- Every character on the player's account, as PetalsCharacter tables sorted by
--- slot. nil on a server with no character system.
exports('getCharacters', function(src) return call('getCharacters', src) end)

--- The saved look of one of the player's own characters: { model, skin }.
exports('getAppearance', function(src, id) return call('getAppearance', src, id) end)

--- Log the player in as one of their own characters. The framework's usual
--- "character chosen" work runs; the client then calls Bridge.enterWorld.
exports('loadCharacter', function(src, id) return call('loadCharacter', src, id) or false end)

--- Create a character in an empty slot and log in as it. data: firstname,
--- lastname, birthdate ('YYYY-MM-DD'), gender (0/1), nationality, height (ESX).
--- Returns the new character's id, or nil.
exports('createCharacter', function(src, data, slot)
    if type(data) ~= 'table' then return nil end
    return call('createCharacter', src, data, slot)
end)

--- Delete one of the player's own characters and everything keyed to it.
exports('deleteCharacter', function(src, id) return call('deleteCharacter', src, id) or false end)

-- Framework info -------------------------------------------------------------

exports('getFramework', function() return Bridge.name end)
exports('isReady', function() return Bridge.ready end)

-- Diagnostics ----------------------------------------------------------------

--- The first thing to run when a script misbehaves on one framework only.
--- Prints what the bridge detected and what it currently reports for the caller,
--- which is usually enough to see whether the problem is the bridge or the
--- script sitting on top of it.
lib.addCommand('syncbridge', {
    help = 'Petals Dept bridge diagnostics',
    params = {
        { name = 'action', type = 'string', help = 'status | debug', optional = true },
        { name = 'value', type = 'string', help = 'on | off', optional = true },
    },
    restricted = 'group.admin',
}, function(source, args)
    if args.action == 'debug' then
        Debug.override = args.value == 'on' or nil
        Debug.warn('debug logging %s', args.value == 'on' and 'ON' or 'back to config')
        return
    end

    local job = call('getJob', source)
    local gang = call('getGang', source)

    local report = {
        ('framework:    %s (Config.Framework = %s)'):format(tostring(Bridge.name), tostring(Config.Framework)),
        ('ready:        %s'):format(tostring(Bridge.ready)),
        ('identifier:   %s'):format(tostring(call('getIdentifier', source))),
        ('name:         %s'):format(tostring(call('getName', source))),
        ('job:          %s [%s] duty=%s boss=%s'):format(
            job and job.name or 'nil', job and job.grade or '-',
            job and job.onDuty or '-', job and job.isBoss or '-'),
        ('gang:         %s [%s]'):format(gang and gang.name or 'nil', gang and gang.grade or '-'),
        ('cash / bank:  %s / %s'):format(
            tostring(call('getMoney', source, 'cash')), tostring(call('getMoney', source, 'bank'))),
        ('admin:        %s (group %s)'):format(
            tostring(call('isAdmin', source)), tostring(call('getGroup', source))),
    }

    print(('^4[petals_bridge]^7 diagnostics\n%s'):format(table.concat(report, '\n')))
end)
