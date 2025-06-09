local core = require("apisix.core")
local http = require("resty.http")
local cjson = require("cjson.safe")
local ngx_encode_base64 = ngx.encode_base64
local ngx_decode_base64 = ngx.decode_base64

local plugin_name = "consumer_quota"

local schema = {
    type = "object",
    properties = {
        count = { type = "integer", minimum = 1 },
        key = {
            type = "string",
            enum = { "consumer_name" },
            default = "consumer_name",
        },
        etcd_host = { type = "string", default = "http://127.0.0.1:2379" },
        rejected_code = { type = "integer", default = 429 },
        rejected_msg = { type = "string", default = "Quota exceeded" },
    },
    required = { "count", "key", "etcd_host" }
}

local _M = {
    version = 0.1,
    priority = 1003,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function etcd_request(conf, method, path, body)
    local httpc = http.new()
    local res, err = httpc:request_uri(conf.etcd_host .. path, {
        method = method,
        body = body and cjson.encode(body) or nil,
        headers = { ["Content-Type"] = "application/json" },
    })

    if not res then
        return nil, "etcd request failed: " .. (err or "unknown")
    end

    return cjson.decode(res.body), nil
end

local function get_quota(conf, key)
    local body, err = etcd_request(conf, "POST", "/v3/kv/range", {
        key = ngx_encode_base64(key)
    })
    if not body or not body.kvs then
        return nil, err
    end

    if #body.kvs == 0 then
        return nil, nil -- Key not found
    end

    local val = ngx_decode_base64(body.kvs[1].value)
    return tonumber(val)
end

local function set_quota(conf, key, val)
    return etcd_request(conf, "POST", "/v3/kv/put", {
        key = ngx_encode_base64(key),
        value = ngx_encode_base64(tostring(val))
    })
end

function _M.access(conf, ctx)
    local consumer = ctx.consumer
    if not consumer then
        return core.response.exit(500, "No consumer found")
    end

    local key = "consumer_quota:" .. consumer.username

    local current, err = get_quota(conf, key)
    if err then
        core.log.error("Failed to get quota from etcd: ", err)
        return core.response.exit(500, "Etcd get failed")
    end

    if not current then
        local ok, err = set_quota(conf, key, conf.count - 1)
        if not ok then
            return core.response.exit(500, "Failed to set initial quota")
        end
    elseif current <= 0 then
        return core.response.exit(conf.rejected_code, conf.rejected_msg)
    else
        -- Decrement quota manually
        local new_val = current - 1
        local ok, err = set_quota(conf, key, new_val)
        if not ok then
            return core.response.exit(500, "Failed to decrement quota")
        end
    end
end

return _M
