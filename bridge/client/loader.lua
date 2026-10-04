---@diagnostic disable: lowercase-global
--- Client-side framework bridge.
---
--- The client half exists mostly to hold a cache. Asking the server for your own
--- job every time a script wants to check it is a round trip for information the
--- client already has, so each framework file keeps this table current from its
--- own events and scripts read it for free.

if not Debug then
    print('^3[petals_bridge]^7 shared/debug.lua was not loaded - run "refresh" then "restart petals_bridge".')
    Debug = setmetatable({}, { __index = function() return function() end end })
end

Bridge = {
    name = nil,
    ready = false,
    loaded = false,   ---@type boolean True once the character is spawned in, not merely connected.
    job = nil,        ---@type PetalsJob|nil
    gang = nil,       ---@type PetalsGang|nil
    identity = nil,   ---@type PetalsIdentity|nil
}

local function started(resource)
    return GetResourceState(resource) == 'started'
end

-- Same ordering rule as the server: Qbox first, because it also answers to
-- qb-core and would otherwise be misdetected.
if Config.Framework and Config.Framework ~= 'auto' then
    Bridge.name = Config.Framework
elseif started('qbx_core') then
    Bridge.name = 'qbox'
elseif started('qb-core') then
    Bridge.name = 'qbcore'
elseif started('es_extended') then
    Bridge.name = 'esx'
else
    Bridge.name = 'standalone'
end

Debug.log('bridge', 'client framework: %s', Bridge.name)

--- The character's needs, 0-100: `{ hunger, thirst, stress }`. A framework
--- that does not keep one leaves it nil, so a HUD hides that bar instead of
--- drawing a wrong one. Framework files replace this.
---@return { hunger: number?, thirst: number?, stress: number? }|nil
function Bridge.getNeeds() return nil end

--- The character's money, `{ cash, bank }`, or nil where it cannot be read on
--- the client. Framework files replace this.
---@return { cash: number?, bank: number? }|nil
function Bridge.getMoney() return nil end

--- Framework files call this instead of writing to Bridge directly, so the
--- normalised events below fire from exactly one place.
---@param job PetalsJob|nil
function Bridge.setJob(job)
    local previous = Bridge.job
    Bridge.job = job

    if not job then return end

    -- Only fire on an actual change. Some frameworks push the full player data
    -- on every metadata write, which would otherwise spam every listener.
    if previous and previous.name == job.name
        and previous.grade == job.grade
        and previous.onDuty == job.onDuty then
        return
    end

    Debug.log('job', 'job changed: %s [%s] duty=%s', job.name, job.grade, tostring(job.onDuty))
    TriggerEvent('petals_bridge:jobChanged', job)
end

---@param gang PetalsGang|nil
function Bridge.setGang(gang)
    local previous = Bridge.gang
    Bridge.gang = gang

    if not gang then return end
    if previous and previous.name == gang.name and previous.grade == gang.grade then return end

    TriggerEvent('petals_bridge:gangChanged', gang)
end

---@param state boolean
function Bridge.setLoaded(state)
    if Bridge.loaded == state then return end
    if state then Bridge.selectPending = false end

    Bridge.loaded = state
    Debug.log('player', 'player %s', state and 'loaded' or 'unloaded')

    TriggerEvent(state and 'petals_bridge:playerLoaded' or 'petals_bridge:playerUnloaded')
end

--- The framework has a character ready and wants a spawn spot picked. Framework
--- files call this from whatever their own character screen sends, so a spawn
--- selector listens to one event instead of four.
---@param isNew boolean a character created just now
---@param loaded boolean the framework already finished loading (ESX, standalone), so finishSpawn has nothing to do
function Bridge.spawnSelect(isNew, loaded)
    Debug.log('player', 'spawn select (new=%s, loaded=%s)', tostring(isNew), tostring(loaded))
    TriggerEvent('petals_bridge:spawnSelect', isNew == true, loaded == true)
end

--- Called by a spawn selector once the ped stands where it was sent. Frameworks
--- that wait for their spawn screen to finish loading replace this.
---@param isNew boolean
function Bridge.finishSpawn(isNew) end

-- Character selection -------------------------------------------------------------

--- True from the moment the framework wants a character picked until one enters
--- the world, so a select screen that starts late still opens.
Bridge.selectPending = false

--- Framework files call this when the player joins without a character, or logs
--- out back to character select.
function Bridge.characterSelect()
    Debug.log('player', 'character select')
    Bridge.selectPending = true
    TriggerEvent('petals_bridge:characterSelect')
end

--- The resource that answers petals_bridge:spawnSelect, recorded by
--- Bridge.onSpawnSelect. Without one running, enterWorld places the ped itself.
local spawnSelector = nil

function Bridge.setSpawnSelector(resource)
    spawnSelector = resource
end

function Bridge.hasSpawnSelector()
    return spawnSelector ~= nil and GetResourceState(spawnSelector) == 'started'
end

local function fadeOut(ms)
    if IsScreenFadedOut() then return end
    DoScreenFadeOut(ms)
    while not IsScreenFadedOut() do Wait(0) end
end

Bridge.fadeOut = fadeOut

local STORY_PEDS = { [`player_zero`] = true, [`player_one`] = true, [`player_two`] = true }

--- Waits (up to `timeout` ms) until the local ped wears a real look rather than
--- the game's default story ped, so the screen never fades in on Michael while
--- the appearance script is still putting the character's look on.
---@param timeout number|nil
---@return boolean
function Bridge.waitForLook(timeout)
    local deadline = GetGameTimer() + (timeout or 5000)
    while STORY_PEDS[GetEntityModel(PlayerPedId())] and GetGameTimer() < deadline do Wait(50) end
    return not STORY_PEDS[GetEntityModel(PlayerPedId())]
end

--- Stand the local ped at coords, ready to play. The screen should be faded out.
---
--- The ped stays frozen until the ground under it has streamed in: left free, it
--- starts falling the moment it lands there and drops through a floor that is
--- not loaded yet. Spawn points are often written at ground level, which puts a
--- ped's feet (a metre below its origin) under the pavement, so it is lifted
--- onto the ground when that is the case.
---@param coords vector4
function Bridge.placePed(coords)
    local ped = PlayerPedId()
    local x, y, z, w = coords.x, coords.y, coords.z, coords.w or 0.0

    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, w)

    local deadline = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end

    -- Probed from just above the spot, so a floor overhead never counts.
    local found, ground = GetGroundZFor_3dCoord(x, y, z + 1.0, false)
    if found and ground > z - 1.0 then
        SetEntityCoordsNoOffset(ped, x, y, ground + 1.0, false, false, false)
    end

    SetEntityCollision(ped, true, true)
    SetEntityVisible(ped, true, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
end

-- Appearance creator ----------------------------------------------------------------

--- Set while the first-look creator the bridge opened for a new character is
--- on its way or open: { since = ms, seen = opened yet, manual = the bridge
--- itself waits for it to close (ESX) }.
local creator = nil

---@param manual boolean|nil the caller clears it with Bridge.creatorFinished
function Bridge.creatorStarted(manual)
    creator = { since = GetGameTimer(), seen = false, manual = manual == true }
end

function Bridge.creatorFinished()
    creator = nil
end

--- What the appearance script says about its editor: true / false, or nil when
--- it cannot say (not illenium-appearance, or an old build without the export).
local function editorOpen()
    if GetResourceState('illenium-appearance') ~= 'started' then return nil end

    local ok, open = pcall(function() return exports['illenium-appearance']:isEditorOpen() end)
    if ok and type(open) == 'boolean' then return open end

    return nil
end

-- How long a requested creator has to open before it is assumed it never will.
local CREATOR_OPEN_TIMEOUT = 10000

--- True while the player is building or editing their look: a character
--- creator or a clothing shop. Anything that would cover it (onboarding, a
--- cutscene) should wait.
---@return boolean
function Bridge.isEditingLook()
    local open = editorOpen()

    if not creator then return open == true end
    if creator.manual then return true end

    -- Without word from the appearance script, the creator is a NUI page with
    -- the mouse.
    if open == nil then open = IsNuiFocused() end

    if open then
        creator.seen = true
        return true
    end

    -- Asked for but not on screen yet: the appearance script is still getting
    -- it ready.
    if not creator.seen and GetGameTimer() - creator.since < CREATOR_OPEN_TIMEOUT then return true end

    creator = nil
    return false
end

--- A character select screen calls this once the server loaded or created the
--- character. With a spawn selector running it takes over from here; without
--- one the ped goes to `coords` (the saved spot, or where new characters start).
--- `direct` goes straight to `coords` even when a selector runs (a fixed first spawn).
--- QB-Core and Qbox work this way; ESX replaces it (see bridge/client/esx.lua).
---@param isNew boolean
---@param coords vector4|nil
---@param direct boolean|nil
function Bridge.enterWorld(isNew, coords, direct)
    Bridge.selectPending = false

    if not (direct and coords) and Bridge.hasSpawnSelector() then
        Bridge.spawnSelect(isNew, false)
        return
    end

    fadeOut(300)
    if coords then Bridge.placePed(coords) end
    Bridge.finishSpawn(isNew)
    -- A new character goes to the creator, which waits for the screen itself
    if not isNew then Bridge.waitForLook() end
    DoScreenFadeIn(500)
end

function Bridge.register(name)
    if Bridge.name ~= name then return false end

    Bridge.ready = true
    return true
end
