local plugin = require("apisix.plugin")
local core = require("apisix.core")

local plugin_name = "consumer_allowlist"

local schema = {
    type = "object",
    properties = {
        whitelist = {
            type = "array",
            items = { type = "string" }
        },
        blacklist = {
            type = "array",
            items = { type = "string" }
        }
    }
}

local _M = {
    version = 0.2,
    priority = 1000,
    name = "consumer_allowlist",
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local consumer = ctx.consumer
    if not consumer or not consumer.username then
        return 401, { message = "Missing consumer identity" }
    end

    local username = consumer.username

    -- Check blacklist first (takes priority)
    if conf.blacklist then
        for _, blocked in ipairs(conf.blacklist) do
            if blocked == username then
                return 403, { message = "Consumer is blacklisted" }
            end
        end
    end

    -- Then check whitelist if defined
    if conf.whitelist then
        local allowed = false
        for _, allowed_name in ipairs(conf.whitelist) do
            if allowed_name == username then
                allowed = true
                break
            end
        end

        if not allowed then
            return 403, { message = "Consumer not in whitelist" }
        end
    end

    -- If neither whitelist nor blacklist matched negatively, allow access
end

return _M
