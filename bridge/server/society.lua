---@diagnostic disable: lowercase-global
--- Society (job) money.
---
--- It lives in whichever banking resource the server runs, not in the
--- framework, so this sits beside the framework files instead of in them. The
--- account is named after the job ('police'); ESX's is 'society_police'.
---
--- Config.Society picks the banking resource: 'auto' uses the first one running,
--- in the order below.

Society = {}

local function started(resource)
    return GetResourceState(resource) == 'started'
end

local function esxAccount(job)
    local p = promise.new()

    TriggerEvent('esx_addonaccount:getSharedAccount', 'society_' .. job, function(account)
        p:resolve(account or false)
    end)

    SetTimeout(2000, function() p:resolve(false) end)

    return Citizen.Await(p) or nil
end

--- Each provider: resource to look for, balance (number or nil when the
--- account does not exist), add and remove (true when the money moved), and
--- create (open an account for a new job) where the resource can do it live.
local PROVIDERS = {
    {
        -- Our own. First in the list: a server running petals_banking wants its
        -- company accounts in the same bank the players use, not in a second
        -- resource keeping a second set of books.
        name = 'sync',
        resource = 'petals_banking',
        balance = function(job)
            local amount = exports.petals_banking:getSocietyMoney(job)
            return type(amount) == 'number' and amount or nil
        end,
        add = function(job, amount, reason) return exports.petals_banking:addSocietyMoney(job, amount, reason) == true end,
        remove = function(job, amount, reason) return exports.petals_banking:removeSocietyMoney(job, amount, reason) == true end,
        create = function(job, label) return exports.petals_banking:openSocietyAccount(job, label) == true end,
    },
    {
        name = 'renewed',
        resource = 'Renewed-Banking',
        balance = function(job)
            local amount = exports['Renewed-Banking']:getAccountMoney(job)
            return type(amount) == 'number' and amount or nil
        end,
        add = function(job, amount) return exports['Renewed-Banking']:addAccountMoney(job, amount) ~= false end,
        remove = function(job, amount) return exports['Renewed-Banking']:removeAccountMoney(job, amount) == true end,
        create = function(job, label) return exports['Renewed-Banking']:CreateJobAccount({ name = job, label = label }, 0) ~= nil end,
    },
    {
        name = 'tgg',
        resource = 'tgg-banking',
        balance = function(job) return tonumber(exports['tgg-banking']:GetSocietyAccountMoney(job)) end,
        add = function(job, amount) return exports['tgg-banking']:AddSocietyMoney(job, amount) ~= false end,
        remove = function(job, amount) return exports['tgg-banking']:RemoveSocietyMoney(job, amount) ~= false end,
    },
    {
        name = 'qb-banking',
        resource = 'qb-banking',
        balance = function(job) return tonumber(exports['qb-banking']:GetAccountBalance(job)) end,
        add = function(job, amount, reason) return exports['qb-banking']:AddMoney(job, amount, reason) ~= false end,
        remove = function(job, amount, reason) return exports['qb-banking']:RemoveMoney(job, amount, reason) ~= false end,
        create = function(job) return exports['qb-banking']:CreateJobAccount(job, 0) ~= false end,
    },
    {
        name = 'qb-management',
        resource = 'qb-management',
        balance = function(job) return tonumber(exports['qb-management']:GetAccount(job)) end,
        add = function(job, amount) return exports['qb-management']:AddMoney(job, amount) ~= false end,
        remove = function(job, amount) return exports['qb-management']:RemoveMoney(job, amount) ~= false end,
    },
    {
        name = 'esx',
        resource = 'esx_addonaccount',
        balance = function(job)
            local account = esxAccount(job)
            return account and tonumber(account.money) or nil
        end,
        add = function(job, amount)
            local account = esxAccount(job)
            if not account then return false end
            account.addMoney(amount)
            return true
        end,
        remove = function(job, amount)
            local account = esxAccount(job)
            if not account or (tonumber(account.money) or 0) < amount then return false end
            account.removeMoney(amount)
            return true
        end,
    },
}

--- The provider in use right now, or nil. Looked up on every call, so a banking
--- resource that starts after this one is still found.
local function provider()
    local choice = Config.Society or 'auto'

    for _, p in ipairs(PROVIDERS) do
        if (choice == 'auto' or choice == p.name) and started(p.resource) then return p end
    end

    return nil
end

local warned = false

local function using()
    local p = provider()

    if not p and not warned then
        warned = true
        Debug.warn('no society banking resource is running (petals_banking, Renewed-Banking, tgg-banking, qb-banking, qb-management or esx_addonaccount) - society money is unavailable')
    end

    return p
end

---@param job string
---@return number|nil nil when there is no banking resource or no account for the job
function Society.balance(job)
    local p = using()
    if not p then return nil end

    local ok, amount = pcall(p.balance, job)
    if not ok then Debug.err('society balance (%s) failed: %s', p.name, tostring(amount)) return nil end

    return amount
end

---@return boolean
function Society.add(job, amount, reason)
    local p = using()
    if not p or Society.balance(job) == nil then return false end

    local ok, moved = pcall(p.add, job, amount, reason)
    return ok and moved == true
end

--- Never takes the account below zero.
---@return boolean
function Society.remove(job, amount, reason)
    local p = using()
    if not p then return false end

    local balance = Society.balance(job)
    if not balance or balance < amount then return false end

    local ok, moved = pcall(p.remove, job, amount, reason)
    return ok and moved == true
end

--- Opens an empty account for the job if it has none. True when it has one
--- afterwards; false where the banking resource cannot open one live
--- (esx_addonaccount needs a database row and a restart).
---@return boolean
function Society.ensure(job, label)
    local p = using()
    if not p then return false end
    if Society.balance(job) ~= nil then return true end
    if not p.create then return false end

    local ok, err = pcall(p.create, job, label or job)
    if not ok then Debug.err('society account for %s (%s) failed: %s', job, p.name, tostring(err)) return false end

    return Society.balance(job) ~= nil
end

---@return string|nil which banking resource is in use
function Society.provider()
    local p = provider()
    return p and p.name or nil
end
