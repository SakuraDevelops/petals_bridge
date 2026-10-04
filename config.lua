Config = {}

-- 'auto' detects the running framework. Force it only to debug a detection
-- problem or to pin a server that runs two cores side by side.
---@type 'auto'|'qbox'|'qbcore'|'esx'|'standalone'
Config.Framework = 'auto'

-- ============================================================================
-- Account names
-- ============================================================================
-- Every Petals script asks for 'cash', 'bank' or 'black'. The bridge translates
-- those three into whatever the running framework actually calls them, so no
-- script ever hardcodes 'black_money' or 'money' again.
Config.Accounts = {
    qbox = { cash = 'cash', bank = 'bank', black = 'black_money' },
    qbcore = { cash = 'cash', bank = 'bank', black = 'black_money' },
    esx = { cash = 'money', bank = 'bank', black = 'black_money' },
}

-- ============================================================================
-- Gangs on ESX
-- ============================================================================
-- ESX has no gang system. Pick how Bridge.getGang behaves there:
--   'none'  - always returns nil. Scripts must handle a gangless server.
--   'job'   - treat the player's job as their gang. Works if you run gangs as
--             jobs, which most ESX servers do.
--   'meta'  - store gang in xPlayer metadata under Config.EsxGangMetaKey.
---@type 'none'|'job'|'meta'
Config.EsxGangMode = 'job'
Config.EsxGangMetaKey = 'gang'

-- ============================================================================
-- Characters on ESX
-- ============================================================================
-- es_extended names each character's users row "<prefix><slot>:<license>".
-- Keep this the same as esx_multicharacter's Config.Prefix if you used it before.
Config.EsxCharacterPrefix = 'char'
-- How birth dates are written to users.dateofbirth (esx_identity's format).
Config.EsxDateFormat = 'DD/MM/YYYY'

-- Admin groups, checked by Bridge.isAdmin. ESX uses getGroup, QB/Qbox use
-- permission levels - the names below cover both.
Config.AdminGroups = { 'admin', 'superadmin', 'god', 'owner' }

-- Where job (society) money lives, for Bridge.getSocietyMoney and friends.
--   'auto'  the first of these that is running:
--   'sync' (petals_banking), 'renewed' (Renewed-Banking), 'tgg' (tgg-banking),
--   'qb-banking', 'qb-management', 'esx' (esx_addonaccount society_<job> accounts)
Config.Society = 'auto'

-- Which resource holds vehicle keys, for Bridge.giveKeys / removeKeys.
--   'auto'  the first of these that is running:
--   'sync' (petals_vehiclekeys), 'qbx' (qbx_vehiclekeys), 'qb' (qb-vehiclekeys)
-- With none running, vehicles need no keys and giving them always succeeds.
Config.VehicleKeys = 'auto'

Config.Debug = {
    enabled = false,
    channels = {
        bridge = true,   -- detection + which framework file answered
        money  = true,
        job    = true,
        player = true,
    },
}
