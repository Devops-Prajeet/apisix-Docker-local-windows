local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "tds_amount_certi_validator"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 750,
    name = plugin_name,
    schema = schema,
}



function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end





function _M.access(conf, ctx)
    local req_body, err = core.request.get_body()
    if not req_body then
        return 400, { message = "Invalid request body", status = "102" }
    end

    local data, err = json.decode(req_body)

    core.log.warn("anilkumar yadav ji...........", data)
    if not data then
        return 400, { message = "Invalid JSON format", status = "102" }
    end



    local tds_cert = data["tds_certificate_no"]
    if not tds_cert or tds_cert == "" then

        return 200, { message = "tds_certificate_no can't be empty", status = "103" }
        
    end

    local tds_amount = data["tds_amount"]
    if not tds_amount or tds_amount == "" then

        return 200, { message = "tds_amount can't be empty", status = "103" }
       
    end
end

return _M
