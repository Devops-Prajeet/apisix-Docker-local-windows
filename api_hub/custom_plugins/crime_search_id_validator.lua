local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "crime_search_id_validator"

local schema = {
    type = "object",
    -- You might want to define some properties here if your plugin
    -- accepts configuration, e.g.,
    -- properties = {
    --     some_setting = {
    --         type = "string",
    --     }
    -- }
}

local _M = {
    version = 0.1,
    priority = 2000,
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local req_body, err = core.request.get_body()
    if not req_body then
        return 400, { MESSAGE = "Missing name or address", status = 125 }
    end

    local data, err = json.decode(req_body)
    if not data then
        return 400, { MESSAGE = "Missing name or address", status = 125 }
    end

  
    local function is_empty(value)
    return not value or value:match("^%s*$")
    end

    if is_empty(data.name) or is_empty(data.address) then
        return 400, { MESSAGE = "Missing name or address", status = 125 }
    end 
end

return _M