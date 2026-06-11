local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "cin_validator"

local schema = {
    type = "object",
    properties = {
        cin = { type = "string", default = "cin" } -- Field to validate CIN
    },
    required = { "cin" }
}

local _M = {
    version = 0.1,
    priority = 700,
    name = plugin_name,
    schema = schema
}

-- CIN validation function
local function is_valid_cin(cin)
    if not cin then
        return false
    end

    -- Trim spaces
    cin = cin:match("^%s*(.-)%s*$")

    -- Convert to uppercase
    cin = cin:upper()

    -- Regex for CIN: 21 characters total
    -- 1 char (L/U), 5 digits, 2 letters, 4 digits, 3 letters, 6 digits
    local pattern = "^[LU]%d%d%d%d%d[A-Z][A-Z]%d%d%d%d[A-Z][A-Z][A-Z]%d%d%d%d%d%d$"

    return #cin == 21 and cin:match(pattern) ~= nil
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- Read request body
    local req_body, err = core.request.get_body()
    if not req_body then
        return 400, { message = "Invalid request body", status = "102" }
    end

    local data, err = json.decode(req_body)
    if not data then
        return 400, { message = "Invalid JSON format", status = "102" }
    end

    local field_name = conf.cin or "cin"
    local cin_value = data[field_name]

    if not cin_value or not is_valid_cin(cin_value) then
        return 400, { message = "Invalid CIN format", status = "102" }
    end
end

return _M
