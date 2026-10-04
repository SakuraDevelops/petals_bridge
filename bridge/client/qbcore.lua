---@diagnostic disable: lowercase-global
--- QB-Core client implementation.
---
--- The event names match Qbox because Qbox inherited them, but the player data
--- comes from the core object rather than an export, so the two files cannot
--- simply be shared.

if not Bridge.register('qbcore') then return end

local core

CreateThread(function()
    core = exports['qb-core']:GetCoreObject()
end)

local function readJob(job)
    if not job then return end

    local level, label = Normalize.grade(job.grade)
    Bridge.setJob(Normalize.job(job.name, job.label, level, label,
        job.onduty, job.isboss, job.payment))
end

local function readGang(gang)
    if not gang then return end

    local level, label = Normalize.grade(gang.grade)
    Bridge.setGang(Normalize.gang(gang.name, gang.label, level, label, gang.isboss))
end

local function readIdentity(data)
    local info = data and data.charinfo
    if not info then return end

    Bridge.identity = Normalize.identity(data.citizenid, data.citizenid,
        info.firstname, info.lastname, info.birthdate, info.gender, info.phone)
end

--- The same metadata Qbox keeps, read through the core object instead.
function Bridge.getNeeds()
    local data = core and core.Functions.GetPlayerData()
    local meta = data and data.metadata
    if not meta then return nil end

    return { hunger = tonumber(meta.hunger), thirst = tonumber(meta.thirst), stress = tonumber(meta.stress) }
end

function Bridge.getMoney()
    local data = core and core.Functions.GetPlayerData()
    local money = data and data.money
    if not money then return nil end

    return { cash = tonumber(money.cash) or 0, bank = tonumber(money.bank) or 0 }
end

local function hydrate()
    if not core then return end

    local data = core.Functions.GetPlayerData()
    if not data or not data.citizenid then return end

    readIdentity(data)
    readJob(data.job)
    readGang(data.gang)
    Bridge.setLoaded(true)
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- The core object is fetched in a thread above, so it may not exist yet on a
    -- cold start. Wait for it rather than silently skipping hydration.
    CreateThread(function()
        while not core do Wait(100) end
        hydrate()
    end)
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', hydrate)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    Bridge.setLoaded(false)
    Bridge.job, Bridge.gang, Bridge.identity = nil, nil, nil
end)

-- Character selection ------------------------------------------------------------

-- What qb-multicharacter listens for: the session starting with no character,
-- and its chooseChar event after /logout (Bridge.logout sends it too).
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(100) end
    if LocalPlayer.state.isLoggedIn then return end

    Bridge.characterSelect()
end)

RegisterNetEvent('qb-multicharacter:client:chooseChar', function()
    Bridge.characterSelect()
end)

-- Spawn selection ----------------------------------------------------------------

-- qb-multicharacter sends qb-spawn's events (cData, isNew, apartments) when a
-- character is picked. The player is not loaded yet. A new character only goes
-- this way with the one-line qb-multicharacter change in petals_spawn's install.md;
-- stock QB spawns it at the default spot instead.
RegisterNetEvent('qb-spawn:client:setupSpawns', function(_, isNew)
    Bridge.spawnSelect(isNew == true, false)
end)

--- What qb-spawn does once a spot is chosen.
function Bridge.finishSpawn(isNew)
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
    TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
    TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)
    TriggerEvent('qb-weathersync:client:EnableSync')

    if isNew then
        Bridge.creatorStarted()
        TriggerEvent('qb-clothes:client:CreateFirstCharacter')
    end
end

RegisterNetEvent('QBCore:Client:OnJobUpdate', readJob)
RegisterNetEvent('QBCore:Client:OnGangUpdate', readGang)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    if not data then return end

    readIdentity(data)
    readJob(data.job)
    readGang(data.gang)
end)
