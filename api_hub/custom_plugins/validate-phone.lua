local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "validate-phone"

local schema = {
    type = "object",
    properties = {
        phone_field = { type = "string", default = "phone" } -- Field to validate
    },
    required = {"phone_field"}
}

local _M = {
    version = 0.1,
    priority = 1000,  -- Higher priority runs earlier
    name = plugin_name,
    schema = schema
}

-- Phone number validation function (accepts +91, +1, or 10-digit numbers)
local function is_valid_phone(phone)
    -- Remove all non-digit characters
    local digits = phone:gsub("%D", "")

    -- Check if the number starts with 6, 7, 8, or 9 and has exactly 10 digits
    return digits:match("^[6789]%d%d%d%d%d%d%d%d%d$") ~= nil
end

 


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- Read request body
    local req_body, err = core.request.get_body()
    if not req_body then
        core.log.error("Failed to get request body: ", err)
        return 400, { message = "Invalid request body" }
    end

    -- Parse JSON
    local data, err = json.decode(req_body)
    if not data then
        core.log.error("Failed to decode JSON body: ", err)
        return 400, { message = "Invalid JSON format" }
    end

    -- Extract phone number field
    local phone = data[conf.phone_field]
    local new_json = json.new()
    -- core.log.warn("JSON decoding after everythigs", new_json.encode(is_valid_phone(phone)) )

    if not phone or not is_valid_phone(phone) then
        return 400, { message = "Invalid phone number format",status = "102"}
    end

    -- Valid phone number, continue request processing
    core.log.info("Valid phone number: " .. phone)
end

return _M
