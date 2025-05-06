local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "financial_year_validator"

local schema = {
    type = "object",
    properties = {
        year_field = { type = "string", default = "financial_year" }
    },
    required = { "year_field" }
}

local _M = {
    version = 0.1,
    priority = 700,
    name = plugin_name,
    schema = schema
}

-- Function to validate financial year format
local function is_valid_financial_year(year_str)
    if not year_str then
        return false
    end

    -- Trim and validate pattern
    year_str = year_str:match("^%s*(.-)%s*$")
    local from_year, to_suffix = year_str:match("^(%d%d%d%d)%-(%d%d)$")

    if not from_year or not to_suffix then
        return false
    end

    local expected_to_suffix = tostring((tonumber(from_year) + 1) % 100)
    if #expected_to_suffix == 1 then
        expected_to_suffix = "0" .. expected_to_suffix
    end

    return expected_to_suffix == to_suffix
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

    local field_name = conf.year_field or "financial_year"
    local year_value = data[field_name]

    if not year_value or not is_valid_financial_year(year_value) then
        return 200, { message = "Invalid financial year format", status = "103" }
    end
end

return _M
