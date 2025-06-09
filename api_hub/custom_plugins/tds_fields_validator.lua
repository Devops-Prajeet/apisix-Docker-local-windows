local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "tds_fields_validator"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 2,
    name = plugin_name,
    schema = schema,
}



function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function generate_transaction_id()
    return tostring(ngx.now() * 1000):gsub("%.", "")
end

core.log.warn("Anil kumar..yadva kumar.........")
local function get_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end


function _M.access(conf, ctx)
    -- Log the body being received for debugging
    local req_body = core.request.get_body()
    core.log.debug("Received request body: ", req_body)

    local req_json, err = json.decode(req_body or "{}")

    if not req_json then
        ctx.skip_response_transform = true  -- prevent response override
        return 400, {
            response_code = 102,
            response_message = "Invalid JSON body",
            success = "False",
            billable = "False",
            input = {},
            transaction_id = generate_transaction_id(),
            request_timestamp = ngx.now(),
            response_timestamp = get_timestamp(),
            result = {}
        }
    end

    -- Check if the body is empty
    if type(req_json) == "table" and next(req_json) == nil then
        ngx.log(ngx.WARN, "Parameter missing")
        core.response.exit(422, {
            response_code = 102,
            response_message = "Request body cannot be empty",
            success = "False",
            billable = "False",
            input = {},
            transaction_id = generate_transaction_id(),
            request_timestamp = ngx.now(),
            response_timestamp = get_timestamp(),
            result = {}
        })
    end

    local tds_amount = req_json["tds_amount"]
    if not tds_amount or tds_amount == "" then
        return 400, {
            response_code = 102,
            response_message = "tds_amount can't be empty",
            success = "False",
            billable = "True",
            input = req_json,
            transaction_id = generate_transaction_id(),
            request_timestamp = ngx.now(),
            response_timestamp = get_timestamp(),
            result = {}
        }
    end
end

return _M
