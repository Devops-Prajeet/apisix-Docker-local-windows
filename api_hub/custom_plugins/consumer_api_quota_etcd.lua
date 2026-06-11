local core = require("apisix.core")
local plugin_name = "consumer_api_quota_etcd"

local schema = {
    type = "object",
    properties = {
        quota_config = {
            type = "object",
            additionalProperties = {
                type = "integer"
            }
        },
        quota_duration = { type = "integer", minimum = 1 }  -- optional duration in seconds
    }
}

local _M = {
    version = 0.4,
    priority = 3000,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_quota_key(consumer, uri)
    local month = os.date("%Y-%m") -- optional if you want monthly path
    return "/quota/" .. month .. "/" .. ngx.escape_uri(consumer) .. "/" .. ngx.escape_uri(uri)
end

local function get_timestamp()
    local now = os.time()
    local milliseconds = string.format("%.6f", ngx.now() % 1):sub(3) -- Get microseconds
    local timezone_offset = os.date("%z") -- Get timezone offset (e.g., +0530)
    local formatted_time = os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. milliseconds .. timezone_offset
    return formatted_time
end

function _M.access(conf, ctx)
    local consumer = ctx.consumer
    if not consumer or not consumer.username then
        return 401, { message = "Missing consumer identity" }
    end

    local consumer_name = consumer.username
    local uri = ctx.var.uri
    local key = get_quota_key(consumer_name, uri)

    local total_quota = conf.quota_config
        and conf.quota_config[consumer_name]
        

    if not total_quota then
        return  
    end

    local res, err = core.etcd.get(key)
    if err then
        core.log.error("ETCD read failed: ", err)
        return 500, { message = "Failed to fetch quota from etcd" }
    end

    local quota_obj
    local now = os.time()
    local quota_duration = conf.quota_duration or 2592000 -- default 30 days

    if res and res.body and res.body.node and res.body.node.value then
        local ok, val = pcall(core.json.decode, res.body.node.value)
        if not ok then
            return 500, { message = "Invalid quota data" }
        end

        quota_obj = val

        

        if not total_quota then
            core.log.error("Quota not configured for consumer: ", consumer_name, ", URI: ", uri)
            return 403, { message = "Quota not configured for consumer '" .. consumer_name .. "' on API '" .. uri .. "'" }
        end

      

    else
        -- create new quota object on first time only
        quota_obj = {
            total_quota = total_quota,
            used_quota = 0,
            remaining_quota = total_quota,
            expires_at = now + quota_duration, -- e.g. 10 seconds for testing
        }
    end

    if quota_obj.used_quota >= quota_obj.total_quota then
        return 429, {
            message = "Quota exceeded",
            consumer = consumer_name,
            uri = uri,
            used_quota = quota_obj.used_quota,
            total_quota = quota_obj.total_quota
        }
    end

    -- update quota
    quota_obj.used_quota = quota_obj.used_quota + 1
    quota_obj.remaining_quota = quota_obj.total_quota - quota_obj.used_quota


    quota_obj.last_updated = get_timestamp()

    -- store in etcd (no TTL used)
    local ok, put_err = core.etcd.set(key, core.json.encode(quota_obj))
    if not ok then
        core.log.error("ETCD write failed: ", put_err)
        return 500, { message = "Failed to update quota in etcd" }
    end

    return
end

return _M
