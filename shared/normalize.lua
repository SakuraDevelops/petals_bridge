---@diagnostic disable: lowercase-global
--- The shapes every framework file must return.
---
--- This file is the contract. A framework file may read whatever it likes out of
--- its own core, but it hands back one of these tables and nothing else. Scripts
--- are written against these shapes, so a field added here has to be filled in by
--- all four framework files or it will be nil on three of them.

Normalize = {}

--- ESX grades are a flat number. QB and Qbox use a table: job.grade.level is the
--- number, job.grade.name is the label. Everything downstream wants both, split
--- apart, so it never has to know which core it came from.
---@return number level, string label
function Normalize.grade(grade)
    if type(grade) == 'table' then
        return tonumber(grade.level) or 0, tostring(grade.name or '')
    end

    return tonumber(grade) or 0, ''
end

---@class PetalsJob
---@field name string        Always set. 'unemployed' when the player has none.
---@field label string
---@field grade number       The numeric level, never a table.
---@field gradeLabel string  '' when the framework has no grade name.
---@field onDuty boolean     ESX spells it onDuty, QB spells it onduty. Here: onDuty.
---@field isBoss boolean     ESX has no boss flag - see the esx file for how it is derived.
---@field salary number

---@return PetalsJob
function Normalize.job(name, label, grade, gradeLabel, onDuty, isBoss, salary)
    return {
        name       = name or 'unemployed',
        label      = label or 'Unemployed',
        grade      = tonumber(grade) or 0,
        gradeLabel = gradeLabel or '',
        onDuty     = onDuty == true,
        isBoss     = isBoss == true,
        salary     = tonumber(salary) or 0,
    }
end

---@class PetalsGang
---@field name string
---@field label string
---@field grade number
---@field gradeLabel string
---@field isBoss boolean

---@return PetalsGang
function Normalize.gang(name, label, grade, gradeLabel, isBoss)
    return {
        name       = name or 'none',
        label      = label or 'No Gang',
        grade      = tonumber(grade) or 0,
        gradeLabel = gradeLabel or '',
        isBoss     = isBoss == true,
    }
end

--- ESX carries a first/last name pair and a license. QB and Qbox carry charinfo
--- and a citizenid. Scripts want one identity table with both slots filled in
--- whether or not the framework has something to put in them.
---@class PetalsIdentity
---@field identifier string  The key you store in your own database tables.
---@field citizenid string   Same as identifier on QB/Qbox, the license on ESX.
---@field firstname string
---@field lastname string
---@field fullname string
---@field birthdate string
---@field gender string
---@field phone string

---@return PetalsIdentity
function Normalize.identity(identifier, citizenid, first, last, birthdate, gender, phone)
    first, last = first or '', last or ''

    return {
        identifier = identifier or '',
        citizenid  = citizenid or identifier or '',
        firstname  = first,
        lastname   = last,
        -- Trimmed because one half being empty would otherwise leave a stray space,
        -- which shows up in NUI and in logs.
        fullname   = (('%s %s'):format(first, last):gsub('^%s+', ''):gsub('%s+$', '')),
        birthdate  = birthdate or '',
        gender     = gender or '',
        phone      = phone or '',
    }
end

---@class PetalsGradeInfo
---@field level number
---@field label string
---@field isBoss boolean
---@field salary number

---@return PetalsGradeInfo
function Normalize.gradeInfo(level, label, isBoss, salary)
    level = tonumber(level) or 0

    return {
        level  = level,
        label  = (label and label ~= '') and tostring(label) or ('Rank %d'):format(level),
        isBoss = isBoss == true,
        salary = tonumber(salary) or 0,
    }
end

---@class PetalsJobInfo
---@field name string
---@field label string
---@field grades PetalsGradeInfo[] lowest level first
---@field type string|nil QB / Qbox job type ('leo', 'ems'...)
---@field defaultDuty boolean on duty when they log in
---@field offDutyPay boolean paid while off duty

--- A job and every grade in it, sorted lowest first whatever order the
--- framework keeps them in (QB keys them by string, ESX by number, Qbox by
--- integer). `raw` is the framework's job table, for the QB / Qbox extras.
---@return PetalsJobInfo
function Normalize.jobInfo(name, label, grades, raw)
    table.sort(grades, function(a, b) return a.level < b.level end)
    raw = raw or {}

    return {
        name = name, label = label or name, grades = grades,
        type = raw.type ~= 'none' and raw.type or nil,
        defaultDuty = raw.defaultDuty ~= false,
        offDutyPay = raw.offDutyPay == true,
    }
end

--- QB and Qbox store gender as 0 / 1, ESX as 'm' / 'f'. nil when it is neither.
---@return 'male'|'female'|nil
function Normalize.gender(value)
    local v = tostring(value or ''):lower()

    if v == '0' or v == 'm' or v == 'male' then return 'male' end
    if v == '1' or v == 'f' or v == 'female' then return 'female' end

    return nil
end

--- A saved position as a vector4, whatever shape the framework stored it in:
--- Qbox keeps a vector4, QB-Core a vector3 or {x, y, z}, ESX {x, y, z, heading}.
--- Returns nil for anything without three usable numbers, so a character that
--- has never been saved reads as "no position" rather than the map origin.
---@return vector4|nil
function Normalize.position(pos)
    local kind = type(pos)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then return nil end

    local x, y, z, w
    if kind == 'table' then
        x, y, z = tonumber(pos.x or pos[1]), tonumber(pos.y or pos[2]), tonumber(pos.z or pos[3])
        w = tonumber(pos.w or pos.heading or pos[4])
    else
        -- Vectors raise on unknown fields, so .heading is never read from one.
        x, y, z = pos.x, pos.y, pos.z
        w = kind == 'vector4' and pos.w or nil
    end

    if not (x and y and z) or (x == 0 and y == 0 and z == 0) then return nil end
    return vec4(x, y, z, w or 0.0)
end

--- Translate the three account names Petals scripts use into the running
--- framework's own names. Anything unrecognised is passed straight through, so a
--- script can still reach a framework-specific account when it truly needs to.
---@param account 'cash'|'bank'|'black'|string
---@param framework string
---@return string
function Normalize.account(account, framework)
    local map = Config.Accounts and Config.Accounts[framework]
    if not map then return account end

    return map[account] or account
end

--- The other way round: a framework's account name ('money' on ESX) as the
--- name Petals scripts use ('cash').
---@return string
function Normalize.accountFrom(name, framework)
    local map = Config.Accounts and Config.Accounts[framework]

    for ours, theirs in pairs(map or {}) do
        if theirs == name then return ours end
    end

    return name
end

--- One character on the account, as a character select screen lists it. Every
--- framework stores these differently (QB/Qbox: a players row per citizenid,
--- ESX: a users row per "char<slot>:<license>"), so the select screen only ever
--- sees this.
---@class PetalsCharacter
---@field id string          Pass back to loadCharacter/deleteCharacter/getAppearance.
---@field slot number        1-based. QB/Qbox: the cid. ESX: the number in "char<slot>:".
---@field firstname string
---@field lastname string
---@field fullname string
---@field birthdate string
---@field gender number      0 male, 1 female.
---@field nationality string
---@field job string         Job label.
---@field grade string       Grade label, '' when there is none.
---@field cash number
---@field bank number
---@field lastPlayed number|nil  Unix time, when the framework records it.
---@field position vector4|nil

---@return PetalsCharacter
function Normalize.character(c)
    local first, last = tostring(c.firstname or ''), tostring(c.lastname or '')
    local gender = c.gender

    -- QB/Qbox store 0/1, ESX 'm'/'f', some forks 'male'/'female'.
    if type(gender) == 'string' then
        local g = gender:lower():sub(1, 1)
        gender = (g == 'f' or g == '1') and 1 or 0
    else
        gender = tonumber(gender) == 1 and 1 or 0
    end

    return {
        id          = tostring(c.id),
        slot        = math.floor(tonumber(c.slot) or 1),
        firstname   = first,
        lastname    = last,
        fullname    = (('%s %s'):format(first, last):gsub('^%s+', ''):gsub('%s+$', '')),
        birthdate   = tostring(c.birthdate or ''),
        gender      = gender,
        nationality = tostring(c.nationality or ''),
        job         = tostring(c.job or 'Unemployed'),
        grade       = tostring(c.grade or ''),
        cash        = tonumber(c.cash) or 0,
        bank        = tonumber(c.bank) or 0,
        lastPlayed  = tonumber(c.lastPlayed),
        position    = Normalize.position(c.position),
    }
end

--- A JSON column that may already be decoded (oxmysql does that for JSON
--- typed columns) or may be broken. Never throws.
---@return table
function Normalize.json(value)
    if type(value) == 'table' then return value end
    if type(value) ~= 'string' or value == '' then return {} end

    local ok, decoded = pcall(json.decode, value)
    return ok and type(decoded) == 'table' and decoded or {}
end

--- Slots come from the cid on QB/Qbox, but old accounts can have gaps or
--- duplicates. Characters keep their order and each gets the first free slot
--- at or after its own number, so two can never share one.
---@param list PetalsCharacter[]
---@return PetalsCharacter[]
function Normalize.slots(list)
    table.sort(list, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        return a.id < b.id
    end)

    local taken = {}
    for _, c in ipairs(list) do
        local slot = math.max(1, c.slot)
        while taken[slot] do slot = slot + 1 end
        taken[slot] = true
        c.slot = slot
    end

    return list
end

--- A model hash both ways round. The same model can come back signed from one
--- native and unsigned from another, so lookups try both.
---@return number[]
function Normalize.hashes(hash)
    hash = tonumber(hash)
    if not hash then return {} end
    if hash < 0 then return { hash, hash + 4294967296 } end
    if hash > 2147483647 then return { hash, hash - 4294967296 } end
    return { hash }
end

---@class PetalsOwnedVehicle
---@field key string     Stays the same for the life of the row (the id, or the plate on ESX).
---@field plate string
---@field owner string   The owner's identifier.
---@field model string   Model name, or the hash as text when the framework only keeps that.
---@field garage string|nil
---@field state 'out'|'garaged'|'impound'

--- QB and Qbox keep the state as 0 out, 1 in a garage, 2 impounded.
---@return 'out'|'garaged'|'impound'
function Normalize.vehicleState(state)
    state = tonumber(state)
    if state == 1 then return 'garaged' end
    if state == 2 then return 'impound' end
    return 'out'
end

--- The other way round, for writing a state back to the table. A number given
--- straight through is passed on, so callers may use either.
---@return integer
function Normalize.vehicleStateId(state)
    if tonumber(state) then return math.floor(tonumber(state)) end
    if state == 'garaged' or state == 'stored' then return 1 end
    if state == 'impound' or state == 'impounded' then return 2 end
    return 0
end
