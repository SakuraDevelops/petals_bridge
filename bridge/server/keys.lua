---@diagnostic disable: lowercase-global
--- Vehicle keys.
---
--- Keys live in whichever keys resource the server runs, not in the framework,
--- so this sits beside the framework files like society.lua does.
---
--- Config.VehicleKeys picks the resource: 'auto' uses the first one running,
--- in the order below. With none running, keys are not a thing on the server
--- and giving them always succeeds.

Keys = {}

local function started(resource)
    return GetResourceState(resource) == 'started'
end

local function plateOf(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)
    return plate and plate:gsub('^%s+', ''):gsub('%s+$', '') or nil
end

--- Each provider: resource to look for, give and remove. Both take the player
--- and the vehicle entity; a provider that works by plate reads it here.
local PROVIDERS = {
    {
        name = 'sync',
        resource = 'petals_vehiclekeys',
        give = function(src, vehicle) return exports.petals_vehiclekeys:giveKeys(src, vehicle, true) ~= false end,
        remove = function(src, vehicle) return exports.petals_vehiclekeys:removeKeys(src, vehicle, true) ~= false end,
    },
    {
        name = 'qbx',
        resource = 'qbx_vehiclekeys',
        -- nil back means "already had them", which is still a yes.
        give = function(src, vehicle) return exports.qbx_vehiclekeys:GiveKeys(src, vehicle, true) ~= false end,
        remove = function(src, vehicle) return exports.qbx_vehiclekeys:RemoveKeys(src, vehicle, true) ~= false end,
    },
    {
        name = 'qb',
        resource = 'qb-vehiclekeys',
        give = function(src, vehicle)
            TriggerClientEvent('vehiclekeys:client:SetOwner', src, plateOf(vehicle))
            return true
        end,
        remove = function(src, vehicle)
            TriggerClientEvent('qb-vehiclekeys:client:RemoveKeys', src, plateOf(vehicle))
            return true
        end,
    },
}

---@return table|nil
local function provider()
    local wanted = Config.VehicleKeys or 'auto'

    for _, p in ipairs(PROVIDERS) do
        if (wanted == 'auto' or wanted == p.name) and started(p.resource) then return p end
    end

    return nil
end

---@param src number
---@param vehicle number entity
---@return boolean
function Keys.give(src, vehicle)
    local p = provider()
    if not p then return true end

    local ok, result = pcall(p.give, src, vehicle)
    if not ok then Debug.err('giveKeys via %s failed: %s', p.name, tostring(result)) end
    return ok and result ~= false
end

---@param src number
---@param vehicle number entity
---@return boolean
function Keys.remove(src, vehicle)
    local p = provider()
    if not p then return true end

    local ok, result = pcall(p.remove, src, vehicle)
    if not ok then Debug.err('removeKeys via %s failed: %s', p.name, tostring(result)) end
    return ok and result ~= false
end
