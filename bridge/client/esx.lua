---@diagnostic disable: lowercase-global
--- ESX client implementation.
---
--- ESX event names share nothing with QB, and its job payload is the flat shape
--- described in bridge/server/esx.lua. Gangs follow Config.EsxGangMode: in 'job'
--- mode the gang mirrors the job, which is how most ESX servers actually run
--- gangs.

if not Bridge.register('esx') then return end

local core

CreateThread(function()
    core = exports['es_extended']:getSharedObject()
end)

local BOSS_GRADES = { boss = true, owner = true, chief = true, manager = true }

-- ESX keeps needs in esx_status, not on the player: it ticks its statuses out
-- as an event, and each one counts up to a million. They are cached here as
-- percentages so reading them costs nothing.
local status = {}

AddEventHandler('esx_status:onTick', function(list)
    for _, entry in ipairs(list or {}) do
        local name = entry.name
        local percent = entry.getPercent and entry.getPercent()
            or (entry.percent or (entry.val and entry.val / 10000))

        if name and percent then status[name] = math.floor(percent + 0.5) end
    end
end)

--- ESX counts hunger and thirst DOWN from full, the same direction QB does, so
--- no flipping is needed. A status no resource provides stays nil.
function Bridge.getNeeds()
    if not next(status) then return nil end
    return { hunger = status.hunger, thirst = status.thirst, stress = status.stress }
end

function Bridge.getMoney()
    local data = core and core.GetPlayerData()
    local accounts = data and data.accounts
    if not accounts then return nil end

    local out = { cash = tonumber(data.money) or 0, bank = 0 }

    for _, account in ipairs(accounts) do
        if account.name == 'bank' then out.bank = tonumber(account.money) or 0 end
        if account.name == 'money' and not data.money then out.cash = tonumber(account.money) or 0 end
    end

    return out
end

local function multichar()
    local config = core and core.GetConfig and core.GetConfig() or {}
    return config.Multichar == true
end

local function readJob(job)
    if not job then return end

    local normalised = Normalize.job(
        job.name, job.label,
        job.grade, job.grade_label or job.grade_name,
        job.onDuty ~= false,
        BOSS_GRADES[tostring(job.grade_name or ''):lower()] == true,
        job.salary or job.grade_salary
    )

    Bridge.setJob(normalised)

    if Config.EsxGangMode == 'job' then
        Bridge.setGang(Normalize.gang(normalised.name, normalised.label,
            normalised.grade, normalised.gradeLabel, normalised.isBoss))
    end
end

local function hydrate(xPlayer)
    xPlayer = xPlayer or (core and core.GetPlayerData())
    if not xPlayer then return end

    Bridge.identity = Normalize.identity(
        xPlayer.identifier, xPlayer.identifier,
        xPlayer.firstName or xPlayer.firstname,
        xPlayer.lastName or xPlayer.lastname)

    readJob(xPlayer.job)
    Bridge.setLoaded(true)
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    CreateThread(function()
        while not core do Wait(100) end

        -- ESX sets isPlayerLoaded once the spawn is complete. Without this check a
        -- restart during character select would cache an empty job.
        if core.IsPlayerLoaded and core.IsPlayerLoaded() then hydrate() end
    end)
end)

-- ESX spawns the character itself: esx_multicharacter (or es_extended alone)
-- places the ped, runs the skin menu for a new character, then sends
-- esx:onPlayerSpawn. The selector opens after that first spawn, so a new
-- character has finished its skin first. esx:onPlayerSpawn also fires on every
-- respawn after death, so only the first one after a load counts.
local pendingSpawn = nil ---@type { isNew: boolean }|nil

--- What es_extended sent with the last load, for Bridge.enterWorld.
local lastLoad = nil ---@type { data: table, isNew: boolean, skin: table|nil }|nil

RegisterNetEvent('esx:playerLoaded', function(xPlayer, isNew, skin)
    lastLoad = { data = xPlayer or {}, isNew = isNew == true, skin = skin }
    hydrate(xPlayer)

    local pending = { isNew = isNew == true }
    pendingSpawn = pending

    -- A build that never sends esx:onPlayerSpawn would leave the selector shut.
    -- A new character is left alone: its skin menu can stay open for minutes.
    if pending.isNew then return end
    SetTimeout(10000, function()
        if pendingSpawn ~= pending then return end
        pendingSpawn = nil
        Bridge.spawnSelect(false, true)
    end)
end)

AddEventHandler('esx:onPlayerSpawn', function()
    local pending = pendingSpawn
    if not pending then return end

    pendingSpawn = nil
    Bridge.spawnSelect(pending.isNew, true)
end)

RegisterNetEvent('esx:onPlayerLogout', function()
    pendingSpawn = nil
    lastLoad = nil
    Bridge.setLoaded(false)
    Bridge.job, Bridge.gang, Bridge.identity = nil, nil, nil

    if multichar() then Bridge.characterSelect() end
end)

-- Character selection ------------------------------------------------------------

-- Only in multicharacter mode. Without it es_extended loads the one character
-- by itself and there is nothing to pick.
CreateThread(function()
    while not core do Wait(100) end
    while not NetworkIsPlayerActive(PlayerId()) do Wait(100) end
    if not multichar() or (core.IsPlayerLoaded and core.IsPlayerLoaded()) then return end

    Bridge.characterSelect()
end)

local function appearanceResource()
    for _, name in ipairs({ 'illenium-appearance', 'fivem-appearance', 'esx_skin' }) do
        if GetResourceState(name) == 'started' then return name end
    end
end

--- A new character (or one saved without a skin) gets a freemode model for its
--- sex and the skin menu, the way esx_multicharacter does it.
local function createSkin(data)
    local female = tostring(data.sex or ''):lower():sub(1, 1) == 'f'
    local model = female and `mp_f_freemode_01` or `mp_m_freemode_01`

    RequestModel(model)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(0) end
    SetPlayerModel(PlayerId(), model)
    SetModelAsNoLongerNeeded(model)

    local skin = { sex = female and 1 or 0 }
    if not appearanceResource() then return skin end

    TriggerEvent('skinchanger:loadSkin', skin)
    DoScreenFadeIn(500)

    local done = false
    TriggerEvent('esx_skin:openSaveableMenu', function() done = true end, function() done = true end)
    while not done do Wait(200) end

    local saved = nil
    TriggerEvent('skinchanger:getSkin', function(s) saved = s end)
    deadline = GetGameTimer() + 2000
    while not saved and GetGameTimer() < deadline do Wait(0) end

    Bridge.fadeOut(500)
    return saved or skin
end

--- es_extended already loaded the character when this runs (esx:playerLoaded is
--- on its way or here). This does esx_multicharacter's part: skin, spawn, and
--- the esx:onPlayerSpawn events - which is what opens a spawn selector on ESX.
function Bridge.enterWorld(isNew, coords, direct)
    Bridge.selectPending = false
    direct = direct == true and coords ~= nil

    local deadline = GetGameTimer() + 15000
    while not lastLoad and GetGameTimer() < deadline do Wait(50) end

    local load = lastLoad
    lastLoad = nil

    if not load then
        Debug.err('enterWorld: es_extended never sent esx:playerLoaded')
        DoScreenFadeIn(500)
        return
    end

    -- Going straight to coords: the selector must not open on the spawn event.
    if direct then pendingSpawn = nil end

    isNew = load.isNew or isNew == true
    local spawn = (not isNew and not direct and Normalize.position(load.data.coords)) or coords
        or Normalize.position(load.data.coords) or vec4(0.0, 0.0, 72.0, 0.0)

    Bridge.fadeOut(300)

    local skin = load.skin
    if isNew or type(skin) ~= 'table' or next(skin) == nil then
        -- The skin menu runs inside createSkin, so it is open for exactly this long.
        Bridge.creatorStarted(true)
        skin = createSkin(load.data)
        Bridge.creatorFinished()
    end

    local function spawned()
        local ped = PlayerPedId()
        FreezeEntityPosition(ped, false)
        SetEntityCollision(ped, true, true)
        SetEntityVisible(ped, true, false)
        SetPlayerControl(PlayerId(), true, 0)

        TriggerServerEvent('esx:onPlayerSpawn')
        TriggerEvent('esx:onPlayerSpawn')
        TriggerEvent('esx:restoreLoadout')

        if direct or not Bridge.hasSpawnSelector() then DoScreenFadeIn(750) end
    end

    local position = { x = spawn.x, y = spawn.y, z = spawn.z, heading = spawn.w }

    -- ESX.SpawnPlayer waits on skinchanger:loadSkin to call back, which never
    -- happens with no skin resource running.
    if appearanceResource() or GetResourceState('skinchanger') == 'started' then
        core.SpawnPlayer(skin, position, spawned)
    else
        Bridge.placePed(spawn)
        NetworkResurrectLocalPlayer(spawn.x, spawn.y, spawn.z, spawn.w, 0, true)
        TriggerEvent('playerSpawned', position)
        spawned()
    end
end

RegisterNetEvent('esx:setJob', readJob)
