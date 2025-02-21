local core = require("apisix.core")
local http = require("resty.http")
local cjson = require("cjson.safe")

local plugin_name = "api_chainer_v2"

local schema = {
    type = "object",
    properties = {
        proxy_url = { type = "string" }
    },
    required = { "proxy_url" }
}

local _M = {
    version = 0.1,
    priority = 10,
    name = plugin_name,
    schema = schema
}

function _M.access(conf, ctx)
    core.log.warn("[custom_proxy] Access phase triggered")

    if not conf.proxy_url then
        core.log.warn("[custom_proxy] No proxy_url provided, skipping proxy request")
        return
    end

    -- Capture the original response
    local original_response = ctx.var.request_body or "{}"
    core.log.warn("[custom_proxy] Captured Original Response: ", original_response)

    -- Parse JSON response safely
    local parsed_response, err = cjson.decode(original_response)
    if not parsed_response then
        core.log.error("[custom_proxy] JSON parse error: ", err)
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say(cjson.encode({ error = "Failed to parse JSON response" }))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Extract only the "result" key
    local extracted_result = parsed_response["result"]
    if not extracted_result then
        core.log.warn("[custom_proxy] 'result' key not found in response")
        extracted_result = "{}"  -- Default to empty JSON
    else
        extracted_result = cjson.encode(extracted_result)
    end

    core.log.warn("[custom_proxy] Extracted 'result' key: ", extracted_result)

    -- Make HTTP request to secondary API
    local httpc = http.new()
    local res, err = httpc:request_uri(conf.proxy_url, {
        method = "POST",
        body = extracted_result,
        headers = {
            ["Content-Type"] = "application/json",
        }
    })

    if not res then
        core.log.error("[custom_proxy] Failed to fetch response from secondary API: ", err)
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say(cjson.encode({ error = "Failed to call secondary API" }))
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    core.log.warn("[custom_proxy] Secondary API Response: ", res.body)

    -- Send the secondary API's response as the final response to the client
    ngx.status = res.status
    ngx.say(res.body)
    return ngx.exit(res.status)
end

return _M
