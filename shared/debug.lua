---@diagnostic disable: lowercase-global
--- Channel-based logging, shared by client and server.
---
--- Silent by default. The channel that earns its keep here is 'bridge': when a
--- script misbehaves on one framework and not another, the first question is
--- always "which framework file answered this call", and that used to mean
--- adding prints by hand.
---
--- Turn channels on in Config.Debug, or at runtime with /syncbridge debug on.

Debug = {}

local COLORS = {
    bridge = '^4',   -- blue
    money  = '^2',   -- green
    job    = '^5',   -- cyan
    player = '^6',   -- magenta
}

local PREFIX = '^7[petals_bridge]'
local SIDE = IsDuplicityVersion and IsDuplicityVersion() and 'server' or 'client'

local function enabled(channel)
    local cfg = Config and Config.Debug
    if not cfg or not cfg.enabled then return false end
    if cfg.channels and cfg.channels[channel] == false then return false end
    return true
end

--- Runtime override set by /syncbridge debug on|off, so you don't have to
--- restart the resource to watch something.
Debug.override = nil

---@param channel string
---@return boolean
function Debug.on(channel)
    if Debug.override ~= nil then return Debug.override end
    return enabled(channel)
end

--- Formats lazily - nothing is built when the channel is off, so leaving these
--- calls in costs effectively nothing.
---@param channel string
---@param fmt string
function Debug.log(channel, fmt, ...)
    if not Debug.on(channel) then return end

    local ok, message = pcall(string.format, fmt, ...)
    if not ok then message = tostring(fmt) end

    print(('%s%s %s[%s]^7 %s'):format(PREFIX, SIDE == 'server' and '' or ' (client)',
        COLORS[channel] or '^7', channel, message))
end

function Debug.warn(fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    print(('^3%s WARN^7 %s'):format(PREFIX, ok and message or tostring(fmt)))
end

function Debug.err(fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    print(('^1%s ERROR^7 %s'):format(PREFIX, ok and message or tostring(fmt)))
end
