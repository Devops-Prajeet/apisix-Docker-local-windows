local core = require("apisix.core")
local json = require("cjson.safe")

local plugin_name = "pan_basic_v1"
local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 1500,
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
end

function _M.body_filter(conf, ctx)
    if ngx.status ~= 200 then
        return
    end

    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if not ngx.ctx.response_body then
        ngx.ctx.response_body = {}
    end

    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.response_body, chunk)
        ngx.arg[1] = nil
    end

    if eof then
        local full_body = table.concat(ngx.ctx.response_body)

        -- Split the concatenated JSON responses
        local source_json, transformed_json = full_body:match("^(%b{})(%b{})$")
        if not source_json or not transformed_json then
            core.log.error("Failed to split response into two JSON objects")
            ngx.arg[1] = full_body
            ngx.arg[2] = true
            return
        end

        local source_data = json.decode(source_json)
        local transformed_data = json.decode(transformed_json)

        if not source_data or not transformed_data then
            core.log.error("Failed to decode either source or transformed JSON")
            ngx.arg[1] = full_body
            ngx.arg[2] = true
            return
        end

        -- Check for status == 3 in original and response_code == 102 in transformed
        if source_data.status == 3 and transformed_data.response_code == 102 then
            transformed_data.response_code = 101
            transformed_data.response_message = "Inactive PAN"
            transformed_data.billable = "True"
            transformed_data.success = "True"
        end

        local final_body = json.encode(transformed_data)
            ngx.arg[1] = final_body
            ngx.arg[2] = true

    end
end

return _M


