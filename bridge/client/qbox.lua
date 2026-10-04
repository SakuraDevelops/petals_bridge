---@diagnostic disable: lowercase-global
--- Qbox client implementation.

if not Bridge.register('qbox') then return end

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

--- Hunger, thirst and stress are metadata on the player, already 0-100.
--- Stress only exists when a stress resource writes it, so it stays nil until
--- one does rather than reading as a full bar.
function Bridge.getNeeds()
    local data = exports.qbx_core:GetPlayerData()
    local meta = data and data.metadata
    if not meta then return nil end

    return { hunger = tonumber(meta.hunger), thirst = tonumber(meta.thirst), stress = tonumber(meta.stress) }
end

function Bridge.getMoney()
    local data = exports.qbx_core:GetPlayerData()
    local money = data and data.money
    if not money then return nil end

    return { cash = tonumber(money.cash) or 0, bank = tonumber(money.bank) or 0 }
end

local function hydrate()
    local data = exports.qbx_core:GetPlayerData()
    if not data then return end

    readIdentity(data)
    readJob(data.job)
    readGang(data.gang)
    Bridge.setLoaded(true)
end

-- A resource restart mid-session misses the login event entirely, so read the
-- current state on start rather than waiting for one that already fired.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if not LocalPlayer.state.isLoggedIn then return end

    hydrate()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', hydrate)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    Bridge.setLoaded(false)
    Bridge.job, Bridge.gang, Bridge.identity = nil, nil, nil
end)

-- Character selection ------------------------------------------------------------

-- With characters.useExternalCharacters = true, qbx_core opens nothing on join
-- and ignores its own logout event, so both are passed on here.
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(100) end
    if LocalPlayer.state.isLoggedIn then return end

    Bridge.characterSelect()
end)

RegisterNetEvent('qbx_core:client:playerLoggedOut', function()
    if GetInvokingResource() then return end -- only from the server
    Bridge.characterSelect()
end)

-- Spawn selection ----------------------------------------------------------------

-- qbx_core sends qb-spawn's events after "Play" and after creating a character
-- (the small petals_spawn edit in qbx_core/client/character.lua adds the second
-- argument: true for a new character). The player is not loaded yet.
RegisterNetEvent('qb-spawn:client:setupSpawns', function(_, isNew)
    Bridge.spawnSelect(isNew == true, false)
end)

--- The same hand-off qbx_core's own spawn does: mark the player loaded on both
--- sides, clear the old housing flags, then open the creator for a new character.
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

--- Fires on any player data change, including duty toggles, which do not emit a
--- job update on their own.
RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    if not data then return end

    readIdentity(data)
    readJob(data.job)
    readGang(data.gang)
end)
