---@diagnostic disable: lowercase-global
--- Items.
---
--- ox_inventory runs on every framework and is asked directly when it is
--- running. Otherwise the framework file answers: ESX's own inventory, or
--- qb-inventory (through its exports or the QB player object).
---
--- Usable items always go through the framework, because that is where
--- ox_inventory, qb-inventory and ESX all look when an item is used.

Items = {}

local function ox()
    return GetResourceState('ox_inventory') == 'started'
end

---@param src number
---@param item string
---@return number
function Items.count(src, item)
    if ox() then
        local ok, count = pcall(function() return exports.ox_inventory:GetItemCount(src, item) end)
        if ok then return tonumber(count) or 0 end
        Debug.err('getItemCount(%s) via ox_inventory failed: %s', item, tostring(count))
        return 0
    end

    return tonumber(Bridge.call('getItemCount', src, item)) or 0
end

---@param src number
---@param item string
---@param count number
---@return boolean
function Items.remove(src, item, count)
    if ox() then
        local ok, removed = pcall(function() return exports.ox_inventory:RemoveItem(src, item, count) end)
        if not ok then Debug.err('removeItem(%s) via ox_inventory failed: %s', item, tostring(removed)) end
        return ok and removed == true
    end

    return Bridge.call('removeItem', src, item, count) == true
end

--- Hands a player an item. `metadata` is ox_inventory metadata (qb-inventory
--- calls it info); frameworks without either ignore it, which is why nothing
--- important should live only in there.
---@param src number
---@param item string
---@param count number
---@param metadata table|nil
---@return boolean
function Items.give(src, item, count, metadata)
    if ox() then
        local ok, added = pcall(function() return exports.ox_inventory:AddItem(src, item, count, metadata) end)
        if not ok then Debug.err('giveItem(%s) via ox_inventory failed: %s', item, tostring(added)) end
        return ok and added ~= false
    end

    return Bridge.call('giveItem', src, item, count, metadata) == true
end

--- Every copy of an item a player is carrying, one entry per stack, with the
--- metadata each carries. A bank card is the reason this exists: which card
--- you can use is decided by the card in your pocket, not by whose name is on
--- the account, and that only works if the metadata can be read back.
---@param src number
---@param item string
---@return table[] { count, metadata }
function Items.search(src, item)
    if ox() then
        local ok, found = pcall(function() return exports.ox_inventory:Search(src, 'slots', item) end)
        if not ok then Debug.err('getItems(%s) via ox_inventory failed: %s', item, tostring(found)) return {} end

        local out = {}
        for _, slot in ipairs(type(found) == 'table' and found or {}) do
            out[#out + 1] = { count = slot.count or 1, slot = slot.slot, metadata = slot.metadata }
        end

        return out
    end

    local found = Bridge.call('getItems', src, item)
    return type(found) == 'table' and found or {}
end

--- Replaces the metadata of the item in one slot. False where the inventory
--- keeps no metadata (ESX's own), so callers must cope without it.
---@param src number
---@param slot number
---@param metadata table
---@return boolean
function Items.setMetadata(src, slot, metadata)
    if ox() then
        local ok, err = pcall(function() return exports.ox_inventory:SetMetadata(src, slot, metadata) end)
        if not ok then Debug.err('setItemMetadata(%s) via ox_inventory failed: %s', tostring(slot), tostring(err)) end
        return ok
    end

    return Bridge.call('setItemMetadata', src, slot, metadata) == true
end

--- Takes one item out of one slot - the phone that was dropped, not any phone.
---@param src number
---@param item string
---@param slot number
---@return boolean
function Items.removeSlot(src, item, slot)
    if ox() then
        local ok, removed = pcall(function() return exports.ox_inventory:RemoveItem(src, item, 1, nil, slot) end)
        if not ok then Debug.err('removeItemSlot(%s) via ox_inventory failed: %s', item, tostring(removed)) end
        return ok and removed == true
    end

    return Bridge.call('removeItemSlot', src, item, slot) == true
end

-- Adding missing items ------------------------------------------------------------
-- So a resource works on first start without anybody editing an item list.

local function luaString(value)
    return ('%q'):format(tostring(value or ''))
end

--- ox_inventory reads data/items.lua once, when it starts, and has no way to
--- add an item while it runs. Missing items are written into that file, inside
--- one marked block per resource, and work after the next restart.
local function oxEnsure(defs, owner)
    local missing = {}
    for _, def in ipairs(defs) do
        local ok, known = pcall(function() return exports.ox_inventory:Items(def.name) end)
        if not (ok and known) then missing[#missing + 1] = def end
    end
    if #missing == 0 then return {} end

    local file = LoadResourceFile('ox_inventory', 'data/items.lua')
    if not file then
        Debug.err('ensureItems: ox_inventory/data/items.lua could not be read')
        return {}
    end

    local lines = { ('\n    -- Added by %s (through petals_bridge). Safe to edit or move.'):format(owner) }
    local names = {}

    for _, def in ipairs(missing) do
        -- A file written earlier but not loaded yet: do not add it twice.
        if not file:find(("['%s']"):format(def.name), 1, true) then
            lines[#lines + 1] = ("    ['%s'] = {"):format(def.name)
            lines[#lines + 1] = ('        label = %s,'):format(luaString(def.label))
            lines[#lines + 1] = ('        weight = %d,'):format(math.floor(tonumber(def.weight) or 0))
            if def.stack == false then lines[#lines + 1] = '        stack = false,' end
            if def.close == false then lines[#lines + 1] = '        close = false,' end
            if def.consume ~= nil then lines[#lines + 1] = ('        consume = %s,'):format(tostring(def.consume)) end
            if def.description then lines[#lines + 1] = ('        description = %s,'):format(luaString(def.description)) end
            lines[#lines + 1] = '    },'
        end
        names[#names + 1] = def.name
    end

    if #lines > 1 then
        -- The file is one "return { ... }": the block goes before its last brace.
        local at = file:match('.*()}')
        if not at then
            Debug.err('ensureItems: ox_inventory/data/items.lua is not the usual "return { }" file')
            return {}
        end

        local updated = file:sub(1, at - 1) .. table.concat(lines, '\n') .. '\n' .. file:sub(at)
        if not SaveResourceFile('ox_inventory', 'data/items.lua', updated, -1) then
            Debug.err('ensureItems: could not write ox_inventory/data/items.lua')
            return {}
        end
    end

    return names
end

--- Item pictures, so the inventory does not show a blank square. Only ever
--- adds a missing picture, never replaces one somebody made.
--- def.image is the item's own picture; def.images adds more under other
--- names, for metadata that picks its picture (a phone in each colour).
local function copyImages(defs, owner, resource, folder)
    local function copy(name, source)
        local target = ('%s/%s.png'):format(folder, name)
        if LoadResourceFile(resource, target) then return end

        local data = LoadResourceFile(owner, source)
        if data then SaveResourceFile(resource, target, data, #data) end
    end

    for _, def in ipairs(defs) do
        if def.image then copy(def.name, def.image) end
        for name, source in pairs(type(def.images) == 'table' and def.images or {}) do
            copy(name, source)
        end
    end
end

--- defs: { { name, label, weight, stack, close, consume, description, image } }
--- where image is a PNG inside the calling resource. Answers the names that
--- were missing - on ox_inventory and ESX those work after a restart.
---@param defs table[]
---@param owner string the resource asking
---@return string[]
function Items.ensure(defs, owner)
    if type(defs) ~= 'table' then return {} end

    if ox() then
        copyImages(defs, owner, 'ox_inventory', 'web/images')
        return oxEnsure(defs, owner)
    end

    if GetResourceState('qb-inventory') == 'started' then
        copyImages(defs, owner, 'qb-inventory', 'html/images')
    end

    local added = Bridge.call('ensureItems', defs)
    return type(added) == 'table' and added or {}
end
