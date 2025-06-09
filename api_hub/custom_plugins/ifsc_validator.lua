local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "ifsc_validator"

local schema = {
    type = "object",
    properties = {
        ifsc_field = { type = "string", default = "ifsc" }
    },
    required = { "ifsc_field" }
}

local _M = {
    version = 0.1,
    priority = 700,
    name = plugin_name,
    schema = schema
}

local function is_valid_ifsc(ifsc)
    if type(ifsc) ~= "string" then
        return false
    end
    ifsc = ifsc:match("^%s*(.-)%s*$")  -- Trim
    ifsc = ifsc:upper()                -- Normalize
    return ifsc:match("^[A-Z][A-Z][A-Z][A-Z]0[0-9][0-9][0-9][0-9][0-9][0-9]$") ~= nil
    -- return ifsc:match("^[A-Z]{4}0%d%d%d%d%d%d$") ~= nil

end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    ngx.req.read_body()
    local req_body = ngx.req.get_body_data()

    if not req_body then
        return 400, { message = "Invalid request body", status = "102" }
    end

    core.log.warn("Raw body data: ", req_body)

    local data, err = json.decode(req_body)
    if not data then
        return 400, { message = "Invalid JSON format", status = "102" }
    end

    local field_name = conf.ifsc_field or "ifsc"
    local ifsc_code = data[field_name]

    core.log.warn("Extracted IFSC field: ", tostring(ifsc_code))

    if not is_valid_ifsc(ifsc_code) then
        return 400, { message = "Invalid IFSC format", status = "102" }
    end

    -- Normalize and update the IFSC field
    data[field_name] = ifsc_code:match("^%s*(.-)%s*$"):upper()
    ngx.req.set_body_data(json.encode(data))
end

return _M