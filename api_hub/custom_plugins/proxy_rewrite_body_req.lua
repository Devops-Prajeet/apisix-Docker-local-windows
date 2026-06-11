local core = require("apisix.core")
local plugin_name = "proxy_rewrite_body_req"
local ngx = ngx
local cjson = require("cjson.safe")

local schema = {
    type = "object",
    properties = {
        keys = {
            type = "object",
            minProperties = 1,
            additionalProperties = {
                type = "string"
            }
        }
    },
    required = { "keys" }
}

local _M = {
    version = 0.1,
    priority = 1000,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()

    local req_body = {}

    if body_data then
        req_body = cjson.decode(body_data)
        if not req_body then
            core.log.warn("Failed to decode JSON body")
            req_body = {}
        end
    end

    -- Inject all key-value pairs from conf.keys
    for key, val in pairs(conf.keys) do
        req_body[key] = val
    end

    local updated_body = cjson.encode(req_body)
    ngx.req.set_body_data(updated_body)

    ngx.req.set_header("Content-Length", #updated_body)
    ngx.req.set_header("Content-Type", "application/json")
end

return _M
