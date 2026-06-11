local core = require("apisix.core")
local plugin_name = "consumer_api_quota_etcd"

local schema = {
    type = "object",
    properties = {
        quota_config = {
            type = "object",
            additionalProperties = {
                type = "object",
                additionalProperties = { type = "integer" }
            }
        }
    }
}

local _M = {
    version = 0.3,
    priority = 1000,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Build etcd key: /quota/YYYY-MM/consumer/uri
local function get_quota_key(consumer, uri)
    local month = os.date("%Y-%m")
    return "/quota/" .. month .. "/" .. ngx.escape_uri(consumer) .. "/" .. ngx.escape_uri(uri)
end

function _M.access(conf, ctx)
    local consumer = ctx.consumer
    if not consumer or not consumer.username then
        return 401, { message = "Missing consumer identity" }
    end

    local consumer_name = consumer.username
    local uri = ctx.var.uri
    local key = get_quota_key(consumer_name, uri)

    -- Get total_quota from plugin config
    local total_quota = nil
    if conf.quota_config
        and conf.quota_config[consumer_name]
        and conf.quota_config[consumer_name][uri] then
        total_quota = tonumber(conf.quota_config[consumer_name][uri])
    end

    if not total_quota then
        return 403, { message = "Quota not configured for consumer '" .. consumer_name .. "' on API '" .. uri .. "'" }
    end

    -- Get usage from etcd
    local res, err = core.etcd.get(key)
    if err then
        core.log.error("ETCD read failed: ", err)
        return 500, { message = "Failed to fetch quota from etcd" }
    end

    local quota_obj = {
        total_quota = total_quota,
        used_quota = 0,
        remaining_quota = total_quota,
        last_updated = ""
    }

    if res and res.body and res.body.node and res.body.node.value then
        local ok, val = pcall(core.json.decode, res.body.node.value)
        if ok then
            quota_obj = val
            quota_obj.total_quota = total_quota  -- enforce from config
            quota_obj.used_quota = tonumber(quota_obj.used_quota or 0)
            quota_obj.remaining_quota = total_quota - quota_obj.used_quota
        end
    end

    -- Check if quota exceeded
    if quota_obj.used_quota >= total_quota then
        return 429, {
            message = "Quota exceeded",
            consumer = consumer_name,
            uri = uri,
            used_quota = quota_obj.used_quota,
            total_quota = total_quota
        }
    end

    -- Update usage
    quota_obj.used_quota = quota_obj.used_quota + 1
    quota_obj.remaining_quota = total_quota - quota_obj.used_quota
    local ist_offset = 5.5 * 3600  -- 19800 seconds
    local ist_time = os.time() + ist_offset
    quota_obj.last_updated = os.date("%Y-%m-%dT%H:%M:%S+05:30", ist_time)

   
    -- ✅ FIXED: Use correct etcd.set() TTL parameter: 2592000
    local ok, put_err = core.etcd.set(key, core.json.encode(quota_obj), nil, 2592000)
    if not ok then
        core.log.error("ETCD write failed: ", put_err)
        return 500, { message = "Failed to update quota in etcd" }
    end

    return
end

return _M
