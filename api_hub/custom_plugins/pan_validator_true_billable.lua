local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "pan_validator_true_billable"

local schema = {
    type = "object",
    properties = {
        pan_field = { type = "string", default = "pan" } -- Field to validate PAN
    },
    required = { "pan_field" }
}

local _M = {
    version = 0.1,
    priority = 650,
    name = plugin_name,
    schema = schema
}

 
local function is_valid_pan(pan)
    -- Trim leading and trailing spaces
    pan = pan:match("^%s*(.-)%s*$")

    -- Convert to uppercase
    pan = pan:upper()

    -- Define the PAN pattern (Lua-Compatible)
    local pan_pattern = "^%u%u%u[%u]%u%d%d%d%d%u$"

    -- Check if the PAN matches the pattern
    return pan:match(pan_pattern) ~= nil
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- Read request body
    local req_body, err = core.request.get_body()
    if not req_body then
        return 400, { message = "Invalid request body",  status = "102"}
    end

    -- Parse JSON
    local data, err = json.decode(req_body)
    if not data then
        return 400, { message = "Invalid JSON format", status = "102" }
    end

    local field_name = conf.pan_field or "pan"  -- Ensure default field name
    local pan_number = data[field_name]

    if not pan_number or not is_valid_pan(pan_number) then
        return 200, { message = "Invalid PAN format", status = "103" }
    end
    
end

return _M