fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'petals_bridge'
author 'Petals Dept'
description 'Petals Dept - framework compatibility layer for ESX, QB-Core and Qbox'
version '1.9.0'

-- Consumers do NOT load the framework files below. They load '@petals_bridge/init.lua'
-- in their own shared_scripts, which builds a Bridge table that proxies into this
-- resource's exports. That way exactly one resource holds a framework connection
-- and one cache, instead of every script opening its own.

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/debug.lua',
    'shared/normalize.lua',
}

client_scripts {
    'bridge/client/loader.lua',
    'bridge/client/qbox.lua',
    'bridge/client/qbcore.lua',
    'bridge/client/esx.lua',
    'bridge/client/standalone.lua',
    'client/appearance.lua',
    'client/exports.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server/loader.lua',
    'bridge/server/vehicles.lua',
    'bridge/server/qbox.lua',
    'bridge/server/qbcore.lua',
    'bridge/server/esx.lua',
    'bridge/server/standalone.lua',
    'bridge/server/society.lua',
    'bridge/server/keys.lua',
    'bridge/server/items.lua',
    'server/exports.lua',
}

-- init.lua is never loaded by this resource. It is the file consumers pull in.
files {
    'init.lua',
}

dependencies {
    'ox_lib',
    'oxmysql',
}
