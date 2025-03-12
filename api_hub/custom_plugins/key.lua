local core = require("apisix.core")
local json = require("cjson.safe")
local ngx = ngx

local plugin_name = "add-keys-to-body"

local schema = {
    type = "object",
    properties = {
        key1 = { type = "string", default = "value1" }, -- Default value for key1
        key2 = { type = "string", default = "value2" }  -- Default value for key2
    }
}

local _M = {
    version = 0.1,
    priority = 900,  -- Execute before most other plugins
    name = plugin_name,
    schema = schema,
}

function _M.access(conf, ctx)
    -- Read the original request body
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()

    -- Decode existing JSON request body (if present)
    local request_body = json.decode(body_data) or {}

    -- Add new keys to the request body
    request_body["consent"] = conf.key1
    request_body["consent_text"] = conf.key2

    -- Encode back to JSON
    local new_body = json.encode(request_body)

    -- Set new request body
    ngx.req.set_body_data(new_body)
    core.log.warn("Updated response body for everythings: repsen body nad body", core.json.encode(conf.key1 ) )
    -- Update Content-Length header
    ngx.req.set_header("Content-Length", #new_body)
end

return _M
