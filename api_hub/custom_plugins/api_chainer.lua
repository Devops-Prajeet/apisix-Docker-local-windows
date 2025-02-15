local core = require("apisix.core")
local http = require("resty.http")

local plugin_name = "api_chainer"

-- Define the plugin schema
local schema = {
    type = "object",
    properties = {
        apis = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    url = { type = "string" },
                    method = { type = "string", enum = { "GET", "POST", "PUT", "DELETE" } },
                    body = { type = "object" },
                    headers = { type = "object" }
                },
                required = { "url", "method" }
            }
        }
    },
    required = { "apis" }
}

-- Define the plugin object
local _M = {
    version = 0.1,
    priority = 10,
    name = plugin_name,
    schema = schema
}

-- Function to make an HTTP request
local function make_request(api_config)
    local httpc = http.new()
    local res, err = httpc:request_uri(api_config.url, {
        method = api_config.method,
        body = api_config.body and core.json.encode(api_config.body) or nil,
        headers = api_config.headers or {
            ["Content-Type"] = "application/json"
        }
    })

    if not res then
        core.log.error("Failed to call API: ", api_config.url, " Error: ", err)
        return nil, err
    end

    return core.json.decode(res.body), nil
end

-- Access phase: Chain APIs
function _M.access(conf, ctx)
    local consolidated_response = {}

    for _, api_config in ipairs(conf.apis) do
        core.log.info("Calling API: ", api_config.url)

        -- Make the API call
        local response, err = make_request(api_config)
        if not response then
            core.log.error("Error during API call: ", err)
            return core.response.exit(500, { error = "Internal Server Error" })
        end

        -- Consolidate the response
        table.insert(consolidated_response, {
            api = api_config.url,
            response = response
        })
    end

    -- Return the consolidated response
    core.response.exit(200, consolidated_response)
end

return _M
