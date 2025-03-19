local core = require("apisix.core")
local plugin = require("apisix.plugin")
local json = require("cjson.safe")

local plugin_name = "response_status_mapper"




local schema = {
    type = "object",
    properties = {
    }
     
}


local _M = {
    version = 0.1,
    priority = 3000,  -- Runs late in the response phase
    name = plugin_name,
    schema = schema
}

-- Define mapping of status to HTTP codes
local status_code_mapping = {
    ["100"] = 400, -- Bad Request (Request data is required)
    ["101"] = 400, -- Bad Request (Phone number is required)
    ["103"] = 400, -- Bad Request (Invalid phone number format)
    ["200"] = 200, -- OK
    ["201"] = 201, -- Created
    ["204"] = 204, -- No Content
    ["403"] = 403, -- Forbidden
    ["404"] = 404, -- Not Found
    ["500"] = 500, -- Internal Server Error
}

-- Store response body in ctx (Used in header_filter phase)
-- function _M.body_filter(conf, ctx)
--     if not ctx.resp_body then
--         ctx.resp_body = ""
--     end

--     local chunk = ngx.arg[1]  -- Capture the response body chunk
--     if chunk then
--         ctx.resp_body = ctx.resp_body .. chunk
--     end
-- end

-- Modify HTTP status in the header_filter phase
function _M.header_filter(conf, ctx)
    local body = ngx.var.requestBodyForStatusCode
    core.log.warn("Updating HTTP status code based on response status: ", body)
    if not body then
        return
    end

    -- Parse the response body as JSON
    local response_data = json.decode(body)
    if not response_data then
        core.log.warn("Failed to decode upstream response JSON")
        return
    end

    -- Extract status key from response body
    local status_key = tostring(response_data.response_code) -- Convert to string to match table keys
    core.log.warn("Updating HTTP status code based on response status: ", status_key)
    if status_key and status_code_mapping[status_key] then
        local new_status = status_code_mapping[status_key]
        core.log.warn("Updating HTTP status code based on response status: ", new_status)
        ngx.status = new_status -- Modify HTTP status
    end
end

-- Plugin schema (Optional, used for validation)
 

-- Plugin registration
function _M.check_schema(conf)
    return true
end

return _M
