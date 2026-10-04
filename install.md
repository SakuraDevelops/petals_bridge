# petals_bridge — install & API

The compatibility layer every Petals Dept script sits on. It talks to ESX, QB-Core and
Qbox so the scripts above it never have to.

---

## Install

1. Drop `petals_bridge` into your resources folder.
2. In `server.cfg`, start it **before** any Petals Dept script:

```cfg
ensure ox_lib
ensure oxmysql
ensure petals_bridge
ensure petals_drugs
ensure petals_business
```

3. That's it. It auto-detects your framework on start. Check with `/syncbridge` in game.

**Requires:** `ox_lib` and `oxmysql` — both of which your framework already needs.

---

## Using it in a script

In your `fxmanifest.lua`:

```lua
shared_scripts {
    '@ox_lib/init.lua',
    '@petals_bridge/init.lua',
    'config.lua',
}

dependencies {
    'petals_bridge',
}
```

Then just call it. Server side takes a `source`, client side doesn't:

```lua
-- server
local job = Bridge.getJob(src)
if job.name == 'police' and job.grade >= 3 then ... end

if Bridge.chargePlayer(src, 500, 'bought a coffee') then
    exports.ox_inventory:AddItem(src, 'coffee', 1)
end

-- client
Bridge.onPlayerLoaded(function()
    print('loaded as', Bridge.getIdentity().fullname)
end)

Bridge.onJobChanged(function(job)
    print('now a', job.label)
end)
```

---

## Normalized shapes

Every framework returns these exact tables. No framework-specific fields leak through.

**Job**
```lua
{ name = 'police', label = 'Police', grade = 3, gradeLabel = 'Sergeant',
  onDuty = true, isBoss = false, salary = 100 }
```

**Gang** — `nil` on ESX unless `Config.EsxGangMode` is set.
```lua
{ name = 'ballas', label = 'Ballas', grade = 2, gradeLabel = 'Enforcer', isBoss = false }
```

**Identity**
```lua
{ identifier = '...', citizenid = '...', firstname = 'John', lastname = 'Doe',
  fullname = 'John Doe', birthdate = '...', gender = '...', phone = '...' }
```

Accounts are always `'cash'`, `'bank'` or `'black'`. The bridge translates to whatever the
framework calls them — you never write `'black_money'` or `'money'` again.

---

## Server API

| Call | Returns |
|---|---|
| `Bridge.getIdentifier(src)` | The key to store in your own tables |
| `Bridge.getIdentity(src)` | Identity table |
| `Bridge.getName(src)` | Character name |
| `Bridge.getSource(identifier)` | Server id, or nil if offline |
| `Bridge.getOnlinePlayers()` | Array of server ids |
| `Bridge.getOfflineName(identifier)` | Name from the DB |
| `Bridge.getMoney(src, account)` | number |
| `Bridge.addMoney(src, account, amount, reason)` | boolean |
| `Bridge.addMoneyByIdentifier(identifier, account, amount, reason)` | boolean — pays a character in the city or not (offline it goes into their saved money) |
| `Bridge.removeMoney(src, account, amount, reason, allowNegative?)` | boolean. `allowNegative` lets a bank account (never cash) go below zero, for bills and fines. ESX follows it; QB-Core and Qbox follow their own `dontAllowMinus` list (bank may go negative by default) |
| `Bridge.chargePlayer(src, amount, reason)` | boolean — cash first, then bank |
| `Bridge.getJob(src)` / `setJob(src, name, grade)` | Job table / boolean |
| `Bridge.hasJob(src, name, minGrade)` | boolean |
| `Bridge.getDuty(src)` / `setDuty(src, bool)` | boolean |
| `Bridge.isBoss(src)` | boolean |
| `Bridge.getGang(src)` / `setGang(src, name, grade)` | Gang table / boolean |
| `Bridge.hasGang(src, name, minGrade)` | boolean |
| `Bridge.getMetadata(src, key)` / `setMetadata(src, key, value)` | any / boolean |
| `Bridge.isAdmin(src)` / `getGroup(src)` | boolean / string |
| `Bridge.logout(src)` | boolean — back to character select (qbx_core, qb-multicharacter, esx_multicharacter); false when there is none |
| `Bridge.getPosition(src)` | vector4 of the character's saved position, or nil (standalone, never saved) |
| `Bridge.getCondition(src)` | `'dead'` \| `'downed'` \| `'cuffed'`, or nil. QB / Qbox: medical + police metadata. ESX: es_extended deaths, esx_ambulancejob, esx_policejob cuffs. Every framework: an `isDead` state bag or a ped with no health |
| `Bridge.getGender(src)` | `'male'` \| `'female'` from the character's identity, or nil when the framework has none |
| `Bridge.getJobInfo(name)` | `{ name, label, grades = { level, label, isBoss, salary }[], type, defaultDuty, offDutyPay }` lowest first, or nil |
| `Bridge.getJobs()` | Every job, as getJobInfo tables |
| `Bridge.getGangInfo(name)` / `getGangs()` | A gang and its grades in the getJobInfo shape / every gang. ESX: none, unless `Config.EsxGangMode = 'job'`, where the jobs stand in |
| `Bridge.saveJob(name, data)` | boolean — create or replace a job while the server runs. `data = { label, type?, defaultDuty?, offDutyPay?, grades = { level, label, salary, isBoss }[] }`. QB / Qbox: live only (jobs.lua is never written), so save your own copy and call it again on start. ESX: written to `jobs` / `job_grades` |
| `Bridge.deleteJob(name)` | boolean — takes everyone out of the job, then removes it. Never `unemployed` |
| `Bridge.getEmployees(job)` | Everyone holding the job, online or not: `{ id, name, grade, online = server id | false, onDuty }` |
| `Bridge.setEmployee(id, job, grade)` | boolean — give a character (citizenid / ESX identifier) the job at `grade`, or change their grade. Online or offline. On Qbox a grade change keeps their main job, a new hire makes it their main one |
| `Bridge.removeEmployee(id, job)` | boolean — take them out of the job (unemployed if it was their main one) |
| `Bridge.getSocietyMoney(job)` | number, or nil with no banking resource / no account (`Config.Society`) |
| `Bridge.addSocietyMoney(job, amount, reason)` / `removeSocietyMoney(...)` | boolean — whole amounts only; never takes an account below zero |
| `Bridge.ensureSocietyAccount(job, label)` | boolean — opens an empty society account for a new job if it has none (Renewed-Banking, qb-banking). False where the banking resource cannot do it live |
| `Bridge.giveKeys(src, vehicle)` / `removeKeys(src, vehicle)` | boolean — keys to a vehicle entity through petals_vehiclekeys, qbx_vehiclekeys or qb-vehiclekeys (`Config.VehicleKeys`). True when no keys resource runs |
| `Bridge.giveVehicle(src, model, garage)` | Plate, or nil — an owned vehicle parked in `garage` (your garage script's name for it). qbx_vehicles on Qbox, `player_vehicles` on QB, `owned_vehicles` on ESX |
| `Bridge.getOwnedVehicles()` | Every owned vehicle: `{ key, plate, owner, model, garage, state = 'out' \| 'garaged' \| 'impound' }`. `key` is the row id (the plate on ESX). One query over the whole table — for a logger comparing now and then, not per frame |
| `Bridge.getVehicleOwner(plate)` | The identifier (as `getIdentifier` gives it) of the character owning a plate, or nil. One query; spaces around the plate are ignored |
| `Bridge.getCharacterVehicles(identifier)` | Every vehicle a character owns: `{ key, plate, owner, model, garage, state, props, fuel, engine, body, depot }`. `props` are the saved vehicle properties (ox_lib shape on Qbox), or nil for a car never saved. For a garage listing one player, not the whole server |
| `Bridge.getVehicle(plate)` | One owned vehicle by plate, same shape, or nil |
| `Bridge.saveVehicle(plate, data)` | boolean — saves `{ garage, state, props, fuel, engine, body, depot, coords }`; anything left out is left alone, so fuel can be saved without touching the garage. `state` is `'out'` \| `'garaged'` \| `'impound'` |
| `Bridge.setVehicleOwner(plate, identifier)` | boolean — signs an owned vehicle over to another character (a garage transfer, a sale). QB and Qbox move the account licence with it |
| `Bridge.deleteVehicle(plate)` | boolean — deletes an owned vehicle outright (sold back to a dealership, scrapped), so no garage lists it again |
| `Bridge.getItemCount(src, item)` / `hasItem(src, item, count?)` | How many of an item a player carries / whether they have at least `count` (default 1). ox_inventory when it runs, otherwise ESX's inventory or qb-inventory |
| `Bridge.removeItem(src, item, count?)` | boolean — takes `count` (default 1); false when the player had too few |
| `Bridge.registerUsableItem(item, cb)` | `cb(src, item)` runs whenever a player uses the item, whichever inventory they use it from (registered with the framework, where ox_inventory, qb-inventory and ESX all look). `item` is `{ name, slot, metadata }` — slot and metadata where the inventory has them, so two copies of an item can be told apart |
| `Bridge.getItems(src, item)` | Every stack of an item a player carries: `{ count, slot, metadata }`. ESX's own inventory has no slots or metadata and answers one plain stack |
| `Bridge.setItemMetadata(src, slot, metadata)` | boolean — replaces the metadata of the item in one slot (ox_inventory, qb-inventory). False on ESX's own inventory, which keeps none |
| `Bridge.removeItemSlot(src, item, slot)` | boolean — takes one of an item out of that slot, not any slot |
| `Bridge.ensureItems(defs)` | Adds items the inventory does not have, so a resource works on first start: `{ { name, label, weight, stack, close, description, image, images } }`, `image` a PNG in the calling resource (`images` more under other names). ox_inventory: written into `data/items.lua` and its `web/images`; QB: added live; ESX: inserted into `items`. Answers the names added — on ox_inventory and ESX they work after a restart |
| `Bridge.getVehicleName(model)` | `{ model, label }` for a model name or hash, from qbx_core / QBCore.Shared.Vehicles / the ESX `vehicles` table, or nil |
| `Bridge.log(kind, src, action, details)` | Hands an action to whatever logs them (petals_logs listens on `petals_bridge:log`). `kind` `'staff'` \| `'job'`; `details` `{ { name, value, inline? }, ... }`. Does nothing when no logger runs, so no script depends on one |
| `Bridge.getCharacters(src)` | Every character on the player's account, sorted by slot: `{ id, slot, firstname, lastname, fullname, birthdate, gender (0/1), nationality, job, grade, cash, bank, lastPlayed, position }`. nil on standalone |
| `Bridge.getAppearance(src, id)` | `{ model, skin }` for one of the player's own characters (playerskins on QB/Qbox, `users.skin` on ESX) |
| `Bridge.loadCharacter(src, id)` | boolean — logs in as one of the player's own characters |
| `Bridge.createCharacter(src, data, slot)` | New character's id, or nil. `data`: `firstname, lastname, birthdate ('YYYY-MM-DD'), gender, nationality, height`. Gives starter items like the stock screen does. Validate first — this trusts its input |
| `Bridge.deleteCharacter(src, id)` | boolean — deletes one of the player's own characters and what the framework keys to it |
| `Bridge.getFramework()` | `'qbox'` \| `'qbcore'` \| `'esx'` \| `'standalone'` |
| `Bridge.getPlayer(src)` | Raw framework object — **escape hatch, ties you to one framework** |
| `Bridge.onPlayerLoaded(cb)` | `cb(src)` every time a character finishes loading |
| `Bridge.onPlayerUnloaded(cb)` | `cb(src)` on logout to character select **or** disconnect — once per load, never twice |

**Server events** (plain `AddEventHandler` in any server script):

| Event | Arguments |
|---|---|
| `petals_bridge:jobChanged` | `src, job, previous` — a different job or grade (both PetalsJob). Not fired on login |
| `petals_bridge:dutyChanged` | `src, onDuty, job` — same job, duty flipped |
| `petals_bridge:moneyChanged` | `src, account, amount, action, reason, balance` — `account` as scripts name it (`'cash'`, `'bank'`...), `action` `'add'` \| `'remove'` \| `'set'` (a set's amount is the new balance) |
| `petals_bridge:log` | `{ kind, resource, source, action, details }` from `Bridge.log` |

`Bridge.isAdmin` reads staff ranks from ACE on QB-Core and Qbox (`add_ace group.admin admin allow`) and from `getGroup` on ESX, checked against `Config.AdminGroups`. A job or gang name never makes someone an admin.

## Client API

| Call | Returns |
|---|---|
| `Bridge.isLoaded()` | boolean — character actually in the world |
| `Bridge.waitForPlayer(timeout)` | boolean — blocks, times out at 30s instead of hanging |
| `Bridge.getJob()` / `getGang()` / `getIdentity()` | Cached tables, no server round trip |
| `Bridge.hasJob(name, minGrade)` / `hasGang(...)` | boolean |
| `Bridge.isOnDuty()` / `isBoss()` | boolean |
| `Bridge.getNeeds()` | `{ hunger, thirst, stress }` 0-100 for a HUD, or nil. Any need the framework does not keep is nil — draw nothing rather than a full bar. QB/Qbox read player metadata; ESX caches esx_status ticks, so it is nil until the first one |
| `Bridge.getMoney()` | `{ cash, bank }` from the client's own cache, or nil where it cannot be read without the server |
| `Bridge.onPlayerLoaded(cb)` | `cb(fromLoad)` now if already loaded (`false`), and on every later load (`true`) |
| `Bridge.onPlayerUnloaded(cb)` | On logout to character select |
| `Bridge.onJobChanged(cb)` / `onGangChanged(cb)` | Only on real changes, not every data push |
| `Bridge.onSpawnSelect(cb)` | `cb(isNew, loaded)` when a spawn spot should be picked — QB/Qbox after a character is chosen or created, ESX and standalone after the first spawn of a login |
| `Bridge.finishSpawn(isNew)` | Hands the character back once the ped is placed: loads the player on QB/Qbox (and opens the creator when `isNew`); nothing on ESX/standalone |
| `Bridge.isEditingLook()` | boolean — the player is building or editing their look: the new-character creator (from the moment the bridge opens it), or an illenium-appearance shop / wardrobe |
| `Bridge.waitForAppearance(settle)` | Blocks until nobody is editing a look, and has not for `settle` ms (2000). Use it before anything that would cover a new character's creator (onboarding, cutscenes) |
| `Bridge.waitForLook(timeout)` | Blocks until the ped wears a real look instead of the default story ped (Michael), up to `timeout` ms (5000). Call before fading in after a spawn; returns false on timeout |
| `Bridge.onCharacterSelect(cb)` | `cb()` when a character should be picked: on joining, and after logging out. Runs straight away if that is already the case |
| `Bridge.enterWorld(isNew, coords, direct)` | After `loadCharacter`/`createCharacter`: hands over to the spawn selector if one runs, otherwise places the ped at `coords`. `direct = true` skips the selector and always goes to `coords`. On ESX it also runs the skin menu for a new character and fires `esx:onPlayerSpawn` |
| `Bridge.getAppearanceModel(appearance, female)` | Model hash for a `getAppearance` result (freemode when unknown) |
| `Bridge.setFuel(vehicle, level)` | Fuel 0-100 through ox_fuel, LegacyFuel, cdn-fuel or ps-fuel, else the game's own fuel level |
| `Bridge.applyAppearance(ped, appearance)` | Dresses **any** ped in a saved look: illenium-appearance / fivem-appearance, skinchanger and qb-clothing formats |

All client getters read a cache kept current by framework events, so they're safe in loops.

---

## Config

| Key | Default | What it does |
|---|---|---|
| `Config.Framework` | `'auto'` | Force detection. Only for debugging or dual-core servers. |
| `Config.Accounts` | — | Account name mapping per framework. |
| `Config.EsxGangMode` | `'job'` | ESX has no gangs. `'job'` mirrors the job, `'meta'` stores it in metadata, `'none'` returns nil. |
| `Config.AdminGroups` | admin, superadmin, god, owner | Groups `isAdmin` accepts. |
| `Config.EsxCharacterPrefix` | `'char'` | ESX character rows are `<prefix><slot>:<license>`. Match your old esx_multicharacter `Config.Prefix`. |
| `Config.EsxDateFormat` | `'DD/MM/YYYY'` | How birth dates are written to `users.dateofbirth`. |
| `Config.VehicleKeys` | `'auto'` | Vehicle keys: `'sync'` (petals_vehiclekeys), `'qbx'` (qbx_vehiclekeys), `'qb'` (qb-vehiclekeys). `'auto'` uses the first running |
| `Config.Society` | `'auto'` | Society banking: `'renewed'`, `'tgg'`, `'qb-banking'`, `'qb-management'`, `'esx'` (esx_addonaccount). `'auto'` uses the first running |
| `Config.Debug` | off | Per-channel logging: `bridge`, `money`, `job`, `player`. |

---

## Diagnostics

`/syncbridge` (admin) prints what the bridge detected and what it currently reports for you:

```
framework:    qbox (Config.Framework = auto)
ready:        true
identifier:   ABCD1234
job:          police [3] duty=true boss=false
gang:         none [0]
cash / bank:  1500 / 24000
admin:        true (group admin)
```

`/syncbridge debug on` turns on channel logging without a restart.

**This is the first thing to run when a script works on one framework and not another** —
it tells you immediately whether the problem is the bridge or the script on top of it.

---

## Framework differences it absorbs

For reference, what the bridge is actually papering over:

| | ESX | QB-Core | Qbox |
|---|---|---|---|
| Identifier | license | citizenid | citizenid |
| Job grade | flat number | `{level, name}` | `{level, name}` |
| Duty field | `onDuty` | `onduty` | `onduty` |
| Gangs | none | `PlayerData.gang` | `GetGang` |
| Metadata | `getMeta` | GetMeta**D**ata | GetMeta**d**ata |
| Cash account | `money` | `cash` | `cash` |
| Dirty money | `black_money` | — | — |
| Loaded event | `esx:playerLoaded` | `QBCore:Client:OnPlayerLoaded` | same as QB |
| Logout (server) | `esx:playerLogout` | `QBCore:Server:OnPlayerUnload` | same as QB |
| Staff rank | `getGroup()` | ACE (`HasPermission`) | ACE — **not** `HasGroup`, which is jobs/gangs |

Two of these bite hardest: QB's `GetMetaData` vs Qbox's `GetMetadata` differ only by one
capital letter and fail silently rather than erroring, and ESX having no gang system at all
means anything gang-related needs `Config.EsxGangMode` set deliberately.

---

## Adding a framework

Copy `bridge/server/standalone.lua` and `bridge/client/standalone.lua`, fill in the
functions, and register under a new name. Add both files to `fxmanifest.lua` and the name to
the detection block in each `loader.lua`. No Petals script needs to change.
