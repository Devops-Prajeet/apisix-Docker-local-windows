local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "pan_validator"

local schema = {
    type = "object",
    properties = {
        pan_field = { type = "string", default = "pan" } -- Field to validate PAN
    },
    required = { "pan_field" }
}

local _M = {
    version = 0.1,
    priority = 700,
    name = plugin_name,
    schema = schema
}

 
local function is_valid_pan(pan)
    if type(pan) ~= "string" then
        return false
    end
    local pan_pattern = "^%u%u%u%u%u%d%d%d%d%u$"

    return pan:match(pan_pattern) ~= nil
end


-- local function is_valid_pan(pan)
--     if type(pan) ~= "string" then
--         return false
--     end

--     -- -- Check for leading/trailing spaces
--     -- if pan ~= pan:match("^%S+$") then
--     --     return false
--     -- end

--     -- PAN strict regex: 5 uppercase letters, 4 digits, 1 uppercase letter
--     return pan:match("^[A-Z]{5}[0-9]{4}[A-Z]$") ~= nil
-- end


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    ngx.req.read_body()
    local req_body = ngx.req.get_body_data()
    if not req_body then
        return 400, { message = "Invalid request body", status = "102" }
    end

    local data, err = json.decode(req_body)
    if not data then
        return 400, { message = "Invalid JSON format", status = "102" }
    end

    local field_name = conf.pan_field or "pan"
    local pan_number = data[field_name]

    if type(pan_number) ~= "string" then
        return 400, { message = "PAN must be a string", status = "102" }
    end

    -- Trim and uppercase the PAN
    pan_number = pan_number:match("^%s*(.-)%s*$"):upper()

    if not is_valid_pan(pan_number) then
        return 400, { message = "Invalid PAN format", status = "102" }
    end

    -- Replace PAN with trimmed version
    data[field_name] = pan_number

    -- Re-encode and replace body
    local new_body = json.encode(data)
    ngx.req.set_body_data(new_body)
end

return _M
