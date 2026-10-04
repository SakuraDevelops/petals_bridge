---@diagnostic disable: lowercase-global
--- Put a saved look on any ped, not just the player's.
---
--- A character select screen shows several characters at once, so it cannot use
--- the usual "load my skin" events, which only ever dress the local player. The
--- look comes back from Bridge.getAppearance in whichever format the server's
--- clothing resource saved it:
---
---   * illenium-appearance / fivem-appearance: { model, components = {...}, props, headBlend, ... }
---   * skinchanger (ESX): { sex, tshirt_1, torso_1, mom, dad, ... }
---   * qb-clothing: { hair = { item, texture }, torso2 = {...}, ... }
---
--- illenium-appearance and fivem-appearance export setPedAppearance, which is
--- used when running. Everything else is applied with natives here, which is a
--- faithful preview but skips tattoos.

Appearance = {}

local function num(value, fallback)
    return tonumber(value) or fallback or 0
end

-- illenium-appearance / fivem-appearance ------------------------------------------

local FACE_FEATURES = {
    'noseWidth', 'nosePeakHigh', 'nosePeakSize', 'noseBoneHigh', 'nosePeakLowering',
    'noseBoneTwist', 'eyeBrownHigh', 'eyeBrownForward', 'cheeksBoneHigh', 'cheeksBoneWidth',
    'cheeksWidth', 'eyesOpening', 'lipsThickness', 'jawBoneWidth', 'jawBoneBackSize',
    'chinBoneLowering', 'chinBoneLenght', 'chinBoneSize', 'chinHole', 'neckThickness',
}

-- Overlay index and colour type (1 hair, 2 makeup, 0 none).
local OVERLAYS = {
    blemishes = { 0, 0 }, beard = { 1, 1 }, eyebrows = { 2, 1 }, ageing = { 3, 0 },
    makeUp = { 4, 2 }, blush = { 5, 2 }, complexion = { 6, 0 }, sunDamage = { 7, 0 },
    lipstick = { 8, 2 }, moleAndFreckles = { 9, 0 }, chestHair = { 10, 1 }, bodyBlemishes = { 11, 0 },
}

local function applyModern(ped, skin)
    local blend = skin.headBlend
    if type(blend) == 'table' then
        SetPedHeadBlendData(ped,
            num(blend.shapeFirst), num(blend.shapeSecond), num(blend.shapeThird),
            num(blend.skinFirst), num(blend.skinSecond), num(blend.skinThird),
            num(blend.shapeMix) + 0.0, num(blend.skinMix) + 0.0, num(blend.thirdMix) + 0.0, false)
    end

    if type(skin.faceFeatures) == 'table' then
        for index, key in ipairs(FACE_FEATURES) do
            local value = tonumber(skin.faceFeatures[key])
            if value then SetPedFaceFeature(ped, index - 1, value + 0.0) end
        end
    end

    if type(skin.headOverlays) == 'table' then
        for key, overlay in pairs(skin.headOverlays) do
            local info = OVERLAYS[key]
            if info and type(overlay) == 'table' then
                SetPedHeadOverlay(ped, info[1], num(overlay.style), num(overlay.opacity) + 0.0)
                if info[2] > 0 then
                    SetPedHeadOverlayColor(ped, info[1], info[2], num(overlay.color), num(overlay.secondColor))
                end
            end
        end
    end

    for _, c in ipairs(type(skin.components) == 'table' and skin.components or {}) do
        SetPedComponentVariation(ped, num(c.component_id), num(c.drawable), num(c.texture), 0)
    end

    for _, p in ipairs(type(skin.props) == 'table' and skin.props or {}) do
        if num(p.drawable, -1) < 0 then
            ClearPedProp(ped, num(p.prop_id))
        else
            SetPedPropIndex(ped, num(p.prop_id), num(p.drawable), num(p.texture), true)
        end
    end

    -- Hair after components: component 2 is the hair style.
    if type(skin.hair) == 'table' then
        SetPedComponentVariation(ped, 2, num(skin.hair.style), num(skin.hair.texture), 0)
        SetPedHairTint(ped, num(skin.hair.color), num(skin.hair.highlight))
    end

    if tonumber(skin.eyeColor) then SetPedEyeColor(ped, num(skin.eyeColor)) end
end

-- skinchanger (ESX) -----------------------------------------------------------------

local SC_COMPONENTS = {
    { 'mask', 1 }, { 'arms', 3 }, { 'pants', 4 }, { 'bags', 5 }, { 'shoes', 6 },
    { 'chain', 7 }, { 'tshirt', 8 }, { 'bproof', 9 }, { 'decals', 10 }, { 'torso', 11 },
}

local SC_PROPS = { { 'helmet', 0 }, { 'glasses', 1 }, { 'ears', 2 }, { 'watches', 6 }, { 'bracelets', 7 } }

-- key prefix, overlay index, colour type
local SC_OVERLAYS = {
    { 'blemishes', 0, 0 }, { 'beard', 1, 1 }, { 'eyebrows', 2, 1 }, { 'age', 3, 0 },
    { 'makeup', 4, 2 }, { 'blush', 5, 2 }, { 'complexion', 6, 0 }, { 'sun', 7, 0 },
    { 'lipstick', 8, 2 }, { 'moles', 9, 0 }, { 'chest', 10, 1 }, { 'bodyb', 11, 0 },
}

local function applySkinchanger(ped, skin)
    local function v(key) return num(skin[key]) end

    if skin.mom or skin.dad then
        SetPedHeadBlendData(ped, v('mom'), v('dad'), 0, v('mom'), v('dad'), 0,
            v('face_md_weight') / 100 + 0.0, v('skin_md_weight') / 100 + 0.0, 0.0, false)
    else
        SetPedHeadBlendData(ped, v('face'), v('face'), v('face'), v('skin'), v('skin'), v('skin'), 1.0, 1.0, 1.0, true)
    end

    SetPedComponentVariation(ped, 2, v('hair_1'), v('hair_2'), 0)
    SetPedHairTint(ped, v('hair_color_1'), v('hair_color_2'))

    for _, entry in ipairs(SC_COMPONENTS) do
        if skin[entry[1] .. '_1'] ~= nil then
            SetPedComponentVariation(ped, entry[2], v(entry[1] .. '_1'), v(entry[1] .. '_2'), 0)
        end
    end

    for _, entry in ipairs(SC_PROPS) do
        local drawable = tonumber(skin[entry[1] .. '_1'])
        if drawable == nil or drawable < 0 then
            ClearPedProp(ped, entry[2])
        else
            SetPedPropIndex(ped, entry[2], drawable, v(entry[1] .. '_2'), true)
        end
    end

    for _, entry in ipairs(SC_OVERLAYS) do
        local key = entry[1]
        if skin[key .. '_1'] ~= nil then
            SetPedHeadOverlay(ped, entry[2], v(key .. '_1'), (tonumber(skin[key .. '_2']) or 10) / 10 + 0.0)
            if entry[3] > 0 then
                SetPedHeadOverlayColor(ped, entry[2], entry[3], v(key .. '_3'), v(key .. '_4'))
            end
        end
    end

    if skin.eye_color ~= nil then SetPedEyeColor(ped, v('eye_color')) end
end

-- qb-clothing ---------------------------------------------------------------------

local QB_COMPONENTS = {
    mask = 1, arms = 3, pants = 4, bag = 5, shoes = 6, accessory = 7,
    ['t-shirt'] = 8, vest = 9, decals = 10, torso2 = 11,
}

local QB_PROPS = { hat = 0, glass = 1, ear = 2, watch = 6, bracelet = 7 }

local QB_OVERLAYS = { beard = { 1, 1 }, eyebrows = { 2, 1 }, ageing = { 3, 0 }, makeup = { 4, 2 }, blush = { 5, 2 }, lipstick = { 8, 2 } }

local function applyQbClothing(ped, skin)
    local function part(key) return type(skin[key]) == 'table' and skin[key] or nil end

    local face = part('face')
    if face then
        local mix = part('facemix') or {}
        SetPedHeadBlendData(ped, num(face.item), num(face.item), 0, num(face.texture), num(face.texture), 0,
            num(mix.shapeMix, 0.5) + 0.0, num(mix.skinMix, 0.5) + 0.0, 0.0, false)
    end

    for key, component in pairs(QB_COMPONENTS) do
        local p = part(key)
        if p then SetPedComponentVariation(ped, component, num(p.item), num(p.texture), 0) end
    end

    local hair = part('hair')
    if hair then
        SetPedComponentVariation(ped, 2, num(hair.item), 0, 0)
        SetPedHairTint(ped, num(hair.texture), num(hair.texture))
    end

    for key, prop in pairs(QB_PROPS) do
        local p = part(key)
        if p then
            if num(p.item, -1) < 0 then
                ClearPedProp(ped, prop)
            else
                SetPedPropIndex(ped, prop, num(p.item), num(p.texture), true)
            end
        end
    end

    for key, info in pairs(QB_OVERLAYS) do
        local p = part(key)
        if p then
            SetPedHeadOverlay(ped, info[1], num(p.item), 1.0)
            if info[2] > 0 then SetPedHeadOverlayColor(ped, info[1], info[2], num(p.texture), 0) end
        end
    end

    local eyes = part('eye_color')
    if eyes then SetPedEyeColor(ped, num(eyes.item)) end
end

-- Public ---------------------------------------------------------------------------

---@return 'modern'|'skinchanger'|'qb-clothing'|nil
function Appearance.format(skin)
    if type(skin) ~= 'table' then return nil end
    if skin.components or skin.headBlend or skin.faceFeatures then return 'modern' end
    if skin.torso_1 ~= nil or skin.tshirt_1 ~= nil or skin.sex ~= nil then return 'skinchanger' end
    if type(skin.torso2) == 'table' or type(skin.hair) == 'table' or type(skin.pants) == 'table' then return 'qb-clothing' end
    return nil
end

--- The model hash for an appearance from Bridge.getAppearance. Falls back to the
--- freemode male so a character with no saved look still has a body.
---@param appearance { model: string|number|nil, skin: table|nil }|nil
---@return number
function Appearance.model(appearance, female)
    local model = appearance and (appearance.model or (type(appearance.skin) == 'table' and appearance.skin.model))

    if type(model) == 'string' then
        model = tonumber(model) or joaat(model)
    end

    if type(model) == 'number' and model ~= 0 and IsModelInCdimage(model) then return model end

    local skin = appearance and appearance.skin
    if female == nil and type(skin) == 'table' then female = skin.sex == 1 end

    return female and `mp_f_freemode_01` or `mp_m_freemode_01`
end

--- Dress a ped that already has the right model.
---@param ped number
---@param appearance { skin: table }|table|nil  Either Bridge.getAppearance's result or a bare skin table.
---@return boolean applied
function Appearance.apply(ped, appearance)
    if not ped or not DoesEntityExist(ped) or type(appearance) ~= 'table' then return false end

    local skin = type(appearance.skin) == 'table' and appearance.skin or appearance
    local format = Appearance.format(skin)
    if not format then return false end

    if format == 'modern' then
        for _, resource in ipairs({ 'illenium-appearance', 'fivem-appearance' }) do
            if GetResourceState(resource) == 'started' then
                local ok = pcall(function() exports[resource]:setPedAppearance(ped, skin) end)
                if ok then return true end
            end
        end
        applyModern(ped, skin)
    elseif format == 'skinchanger' then
        applySkinchanger(ped, skin)
    else
        applyQbClothing(ped, skin)
    end

    return true
end
