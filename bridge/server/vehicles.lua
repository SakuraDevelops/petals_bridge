---@diagnostic disable: lowercase-global
--- The `player_vehicles` table, shared by the QB-Core and Qbox implementations.
---
--- Both frameworks keep owned vehicles in the same table, so the reading and
--- writing lives here once. Columns differ between builds (older QB has no
--- `fuel` / `engine` / `body`, some forks add their own), so every query is
--- built from the columns the table actually has, looked up once.

VehicleStore = {}

local columns

--- The column names on player_vehicles, or an empty set when the table is
--- missing (a server with no owned vehicles at all).
local function known()
    if not columns then
        columns = {}

        local rows = MySQL.query.await([[
            SELECT COLUMN_NAME AS name FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles'
        ]]) or {}

        for _, row in ipairs(rows) do columns[row.name] = true end
    end

    return columns
end

local function has(column) return known()[column] == true end

--- The SELECT list: the columns we want that this table has.
local function selection()
    local wanted = { 'id', 'citizenid', 'plate', 'vehicle', 'mods', 'garage', 'state',
        'fuel', 'engine', 'body', 'depotprice' }
    local list = {}

    for _, name in ipairs(wanted) do
        if has(name) then list[#list + 1] = ('`%s`'):format(name) end
    end

    return table.concat(list, ', ')
end

local function decode(text)
    if type(text) ~= 'string' or text == '' then return nil end
    local ok, value = pcall(json.decode, text)
    return (ok and type(value) == 'table') and value or nil
end

--- One database row as the bridge's vehicle shape.
local function shape(row)
    local props = decode(row.mods)

    return {
        key = tostring(row.id),
        plate = row.plate,
        owner = row.citizenid,
        model = row.vehicle,
        garage = row.garage,
        state = Normalize.vehicleState(row.state),
        props = props,
        -- The columns are the truth when they exist; older tables keep these
        -- inside the saved properties only.
        fuel = tonumber(row.fuel) or (props and tonumber(props.fuelLevel)) or nil,
        engine = tonumber(row.engine) or (props and tonumber(props.engineHealth)) or nil,
        body = tonumber(row.body) or (props and tonumber(props.bodyHealth)) or nil,
        depot = tonumber(row.depotprice) or 0,
    }
end

--- Every vehicle a character owns.
function VehicleStore.byOwner(identifier)
    if not has('plate') then return {} end

    local rows = MySQL.query.await(
        ('SELECT %s FROM `player_vehicles` WHERE `citizenid` = ?'):format(selection()), { identifier }) or {}

    local list = {}
    for _, row in ipairs(rows) do list[#list + 1] = shape(row) end
    return list
end

--- One vehicle by plate, or nil. Plates are stored trimmed, but a fork that
--- keeps GTA's padding would miss on an exact match, hence the TRIM.
function VehicleStore.byPlate(plate)
    if not has('plate') then return nil end

    local row = MySQL.single.await(
        ('SELECT %s FROM `player_vehicles` WHERE `plate` = ? OR TRIM(`plate`) = ? LIMIT 1'):format(selection()),
        { plate, plate })

    return row and shape(row) or nil
end

--- Signs a vehicle over to another character. QB keeps the owner's account
--- licence beside the citizenid, so both move or the car half belongs to two
--- people - qb-garages reads the citizenid, some shops read the licence.
---@return boolean
function VehicleStore.setOwner(plate, identifier)
    if not has('citizenid') then return false end

    local crumbs, values = { '`citizenid` = ?' }, { identifier }

    if has('license') then
        local license = MySQL.scalar.await('SELECT `license` FROM `players` WHERE `citizenid` = ? LIMIT 1', { identifier })
        if license then
            crumbs[#crumbs + 1] = '`license` = ?'
            values[#values + 1] = license
        end
    end

    values[#values + 1] = plate
    values[#values + 1] = plate

    local affected = MySQL.update.await(
        ('UPDATE `player_vehicles` SET %s WHERE `plate` = ? OR TRIM(`plate`) = ?'):format(table.concat(crumbs, ', ')),
        values)

    return (affected or 0) > 0
end

--- Deletes an owned vehicle outright: a car sold back to a dealership, or
--- scrapped. The row goes, so every garage stops listing it.
---@return boolean
function VehicleStore.remove(plate)
    if not has('plate') then return false end

    local affected = MySQL.update.await(
        'DELETE FROM `player_vehicles` WHERE `plate` = ? OR TRIM(`plate`) = ?', { plate, plate })

    return (affected or 0) > 0
end

--- Writes the parts of `data` this table can hold. Anything left out of `data`
--- is left alone, so a caller can save fuel without touching the garage.
function VehicleStore.save(plate, data)
    if not has('plate') then return false end

    local crumbs, values = {}, {}

    local function set(column, value)
        if value == nil or not has(column) then return end
        crumbs[#crumbs + 1] = ('`%s` = ?'):format(column)
        values[#values + 1] = value
    end

    set('garage', data.garage)
    if data.state ~= nil then set('state', Normalize.vehicleStateId(data.state)) end
    if data.props ~= nil then set('mods', json.encode(data.props)) end

    -- The dedicated columns follow the properties when both are given, so the
    -- two never disagree.
    local props = type(data.props) == 'table' and data.props or nil
    set('fuel', data.fuel or (props and props.fuelLevel))
    set('engine', data.engine or (props and props.engineHealth))
    set('body', data.body or (props and props.bodyHealth))
    set('depotprice', data.depot)
    if data.coords ~= nil then set('coords', json.encode(data.coords)) end

    if #crumbs == 0 then return false end

    values[#values + 1] = plate
    values[#values + 1] = plate

    local affected = MySQL.update.await(
        ('UPDATE `player_vehicles` SET %s WHERE `plate` = ? OR TRIM(`plate`) = ?'):format(table.concat(crumbs, ', ')),
        values)

    return (affected or 0) > 0
end
