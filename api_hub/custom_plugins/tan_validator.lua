local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "tan_validator"

local schema = {
    type = "object",
    properties = {
        tan_field = { type = "string", default = "tan" } -- Field to validate TAN
    },
    required = { "tan_field" }
}

local _M = {
    version = 0.1,
    priority = 600,
    name = plugin_name,
    schema = schema
}

-- Function to validate TAN: 4 letters, 5 digits, 1 letter
local function is_valid_tan(tan)
    tan = tan:match("^%s*(.-)%s*$")  -- trim whitespace
    tan = tan:upper()                -- normalize to uppercase
    return tan:match("^%u%u%u%u%d%d%d%d%d%u$") ~= nil
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local req_body, err = core.request.get_body()
    if not req_body then
        return 400, { message = "Invalid request body", status = "102" }
    end

    local data, err = json.decode(req_body)
    if not data then
        return 400, { message = "Invalid JSON format", status = "102" }
    end

    local field_name = conf.tan_field or "tan"
    local tan_number = data[field_name]

    if not tan_number or not is_valid_tan(tan_number) then
        return 200, { message = "Invalid TAN format", status = "103" }
    end
end

return _M
