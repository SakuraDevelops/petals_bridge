# petals_bridge

The free framework bridge behind every **Petals Dept** FiveM script. It talks to ESX, QB-Core and Qbox, so the scripts built on it work on all three without a single framework-specific line.

**Support and updates:** [discord.gg/PetalsDept](https://discord.gg/PetalsDept)

## What it works with

| | Supported |
|---|---|
| **Frameworks** | Qbox, QB-Core, ESX (auto-detected), and a standalone fallback |
| **Inventories** | ox_inventory, qb-inventory, ESX's own |
| **Vehicle keys** | petals_vehiclekeys, qbx_vehiclekeys, qb-vehiclekeys |
| **Society money** | petals_banking, Renewed-Banking, TGG Banking, qb-banking, qb-management, esx_addonaccount |
| **Fuel** | ox_fuel, LegacyFuel, cdn-fuel, ps-fuel |
| **Appearance** | illenium-appearance / fivem-appearance, skinchanger, qb-clothing |
| **Characters** | qbx_core, qb-multicharacter, esx_multicharacter |

## Install

1. Download the latest release (or **Code → Download ZIP**) and put the `petals_bridge` folder in your resources.
2. Start it after `ox_lib` and `oxmysql`, and before any Petals Dept script:

   ```cfg
   ensure ox_lib
   ensure oxmysql
   ensure petals_bridge
   ```

3. Done. It finds your framework by itself; `/syncbridge` in game (admin) shows what it detected.

## For developers

Load it in your own script and call one API on every framework:

```lua
-- fxmanifest.lua
shared_scripts { '@ox_lib/init.lua', '@petals_bridge/init.lua' }
dependencies { 'petals_bridge' }
```

```lua
-- server
if Bridge.hasJob(src, 'police', 3) and Bridge.chargePlayer(src, 500, 'Coffee') then
    -- ...
end
```

Jobs, gangs, money, items, vehicles, characters, society accounts and more come back in the same shape everywhere. The full API and config are in [install.md](install.md).

## Licence

Copyright (C) 2026 Petals Dept

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.

In short: use it on any server, change it as you like, and if you share a changed copy, keep it under GPL-3.0 with this credit.
