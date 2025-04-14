local core = require("apisix.core")
local ngx = ngx
local plugin_name = "required_keys"

local schema = {
    type = "object",
    properties = {
        required_keys = {
            type = "array",
            items = { type = "string" },
            minItems = 1,
        }
    },
    required = { "required_keys" }
}

local _M = {
    version = 0.1,
    priority = 1001,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()

    if not json_body then
        return core.response.exit(400, { message = "Request body is missing" })
    end

    -- Check for the first required key in the body
    if not json_body[required_key_1] then
        return core.response.exit(400, { status = "102", message = required_key_1 .. " is missing" })
    end

    -- Check for the second required key in the body
    if not json_body[required_key_2] then
        return core.response.exit(400, { status = "102", message = required_key_2 .. " is missing" })
    end

    local pan = json_body[required_key_1]
    if not isValidPAN(pan) then
        return core.response.exit(400, { status = "3", message = "Invalid PAN" })
    end

    -- If both keys exist and PAN is valid, allow the request to continue
    return 200
 
end

return _M
