local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "voter_id_validator"

local schema = {
    type = "object",
    properties = {
        voter = { type = "string", default = "voter" } -- Field to validate voter ID
    },
    required = { "voter" }
}

local _M = {
    version = 0.1,
    priority = 700,
    name = plugin_name,
    schema = schema
}

-- Voter ID validation function
local function is_valid_voter_id(voter_id)
    -- Trim leading and trailing spaces
    voter_id = voter_id:match("^%s*(.-)%s*$")

    -- Convert to uppercase
    voter_id = voter_id:upper()

    -- Regex pattern: 2-3 letters followed by 7-13 digits
    local pattern = "^[A-Z][A-Z]?[A-Z]?%d%d%d%d%d%d%d%d?%d?%d?%d?$"

    return voter_id:match(pattern) ~= nil
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

    local field_name = conf.voter or "voter"
    local voter_id = data[field_name]

    if not voter_id or not is_valid_voter_id(voter_id) then
        return 400, { message = "Invalid Voter ID format", status = "102" }
    end
end

return _M
