local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "aadhaar_validator"

local schema = {
    type = "object",
    properties = {
        aadhaar_field = { type = "string", default = "aadhaar" } -- Field to validate Aadhaar
    },
    required = { "aadhaar_field" }
}

local _M = {
    version = 0.1,
    priority = 750,  -- Higher priority for validation
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function is_valid_aadhaar(aadhaar)
    if not aadhaar then
        return false, "Aadhaar number is required", 102
    end

    -- Trim spaces
    local trimmed_aadhaar = aadhaar:match("^%s*(.-)%s*$")

    -- Check if it contains spaces within the string
    if aadhaar:match("%s") then
        return false, "Aadhaar should not contain spaces", 104
    end

    -- Check if it contains only digits
    if not trimmed_aadhaar:match("^%d+$") then
        return false, "Enter only digits", 103
    end

    -- Check length (must be exactly 12 digits)
    if #trimmed_aadhaar < 12 then
        return false, "Invalid Aadhaar number: Less than 12 digits", 102
    elseif #trimmed_aadhaar > 12 then
        return false, "Invalid Aadhaar number: More than 12 digits", 102
    end

    return true
end

local function json_response(status, message, response_code)
    local result = {
        status = tostring(response_code),
        message = message
    }
    -- Pretty-print JSON response
    local formatted_response = json.encode(result)
    return status, formatted_response, { ["Content-Type"] = "application/json" }
end

function _M.access(conf, ctx)
    -- Read request body
    local req_body, err = core.request.get_body()
    if not req_body then
        return json_response(400, "Invalid request body", 102)
    end

    -- Parse JSON
    local data, err = json.decode(req_body)
    if not data then
        return json_response(400, "Invalid JSON format", 102)
    end

    local field_name = conf.aadhaar_field or "aadhaar"
    local aadhaar_number = data[field_name]

    local valid, error_message, response_code = is_valid_aadhaar(aadhaar_number)
    if not valid then
        return json_response(400, error_message, response_code)
    end
end

return _M
