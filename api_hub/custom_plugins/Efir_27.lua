local core   = require("apisix.core")
local http   = require("resty.http")
local string = string
local pairs  = pairs
local cjson  = require("cjson.safe")
local ngx    = ngx

local plugin_schema = {
    type = "object",
    properties = {
        nodes = {
            type = "array",
            minItems = 1,
            items = {
                type = "object",
                properties = {
                    url = { type = "string", minLength = 1 },
                    ssl_verify = { type = "boolean", default = false },
                    timeout = { type = "integer", minimum = 1, maximum = 6000000, default = 60000 },
                    keepalive = { type = "boolean", default = true },
                    keepalive_timeout = { type = "integer", minimum = 1000, default = 600000 },
                    keepalive_pool = { type = "integer", minimum = 1, default = 5 },
                },
                required = { "url" },
            },
        },
    },
}

local plugin_name = "Efir"

local _M = {
    version  = 0.1,
    priority = 1750,
    name     = plugin_name,
    schema   = plugin_schema,
}

local function sanitize_string(value)
    if type(value) ~= "string" then
        return value
    end
    value = value:gsub("[%z\1-\31\127]", "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    return value
end

local function deep_sanitize(tbl)
    if type(tbl) ~= "table" then return tbl end
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            tbl[k] = sanitize_string(v)
        elseif type(v) == "table" then
            tbl[k] = deep_sanitize(v)
        end
    end
    return tbl
end

function _M.check_schema(conf)
    
    local ok, err = core.schema.check(plugin_schema, conf)
    if not ok then
        return false, err
    end
    return true
end

local function address_classification(address)
    local httpc = http.new()
    local ok, body_data = pcall(cjson.encode, { address = address })
    if not ok then
        return nil, "JSON encode error"
    end

    local res, err = httpc:request_uri("https://www.timbleglance.com/api/address_classification/", {
        method = "POST",
        ssl_verify = false,
        headers = {
            ["app-id"] = "K&I54tg54t45@WEFG%T^y^Hr54etgYarjn",
            ["Content-Type"] = "application/json",
            ["api-key"] = "O)L(h5r4tgfb3t4grftfht%5w$45pgtoarjn",
        },
        body = body_data
    })

    if not res then
        core.log.warn("Address classification failed: ", err)
        return nil, err
    end

    if not res.body then
        core.log.warn("Address classification response has no body")
        return nil, "No response body"
    end

    local ok2, decoded = pcall(cjson.decode, res.body)
    if not ok2 or not decoded then
        core.log.warn("Failed to decode address classification: ", res.body)
        return nil, "JSON decode error"
    end

    return decoded, nil
end

local function levenshtein_distance(str1, str2)
    local len1, len2 = #str1, #str2
    if len1 == 0 then return len2 end
    if len2 == 0 then return len1 end

    local matrix = {}
    for i = 0, len1 do matrix[i] = {[0] = i} end
    for j = 0, len2 do matrix[0][j] = j end

    for i = 1, len1 do
        for j = 1, len2 do
            local cost = (str1:sub(i, i) == str2:sub(j, j)) and 0 or 1
            matrix[i][j] = math.min(
                matrix[i - 1][j] + 1,
                matrix[i][j - 1] + 1,
                matrix[i - 1][j - 1] + cost
            )
        end
    end

    return matrix[len1][len2]
end

local function string_similarity(str1, str2)
    if not str1 or not str2 or str1 == "" or str2 == "" then
        return 0
    end

    str1, str2 = str1:lower(), str2:lower()
    local dist = levenshtein_distance(str1, str2)
    local max_len = math.max(#str1, #str2)
    return math.floor((1 - dist / max_len) * 100)
end

function _M.access(conf, ctx)
    ngx.req.set_header("Accept-Encoding", "identity")

    local last_resp, err
    local flag, found = true, false

    for _, node in ipairs(conf.nodes) do
        local params = {
            method = "POST",
            ssl_verify = false,
        }

        local httpc = http.new()
        httpc:set_timeout(node.timeout)

        if last_resp then
            local decoded_body, err = core.json.decode(last_resp.body)
            if not decoded_body then
                core.log.warn("Failed to decode last_resp.body")
                return 500, "JSON decoding failed"
            end

            local statusCode = tonumber(decoded_body.status or decoded_body.response_code or decoded_body.status_code)
            if statusCode ~= 101 and statusCode ~= 200 then
                decoded_body.status = statusCode
                deep_sanitize(decoded_body)
                return core.response.exit(last_resp.status, decoded_body)
            end

            if decoded_body.result then
                decoded_body = { task_id = decoded_body.result.task_id }
            else
                decoded_body = {}
            end

            params.body = core.json.encode(decoded_body)
        else
            params.method = core.request.get_method()
            params.query = core.request.get_uri_args()
            local body, err = core.request.get_body()
            if err then
                core.log.warn("Failed to get request body: ", err)
                return 503
            end
            params.body = body
        end

        local start_time = ngx.now()
        local resp_json

        while (ngx.now() - start_time) < 15 do
            last_resp, err = httpc:request_uri(node.url, {
                method = "POST",
                body = params.body,
                headers = {
                    ["Content-Type"] = "application/json",
                    ["api-key"] = "123456789",
                },
                ssl_verify = false
            })

            if last_resp and last_resp.body then
                local ok, decoded = pcall(core.json.decode, last_resp.body)
                if not ok then
                    core.log.warn("Failed to decode upstream response: ", last_resp.body)
                elseif flag then
                    flag = false
                    resp_json = decoded
                    break
                elseif decoded and (decoded.response_message == "Processing done" or decoded.response_message == "Success") then
                    found = true
                    resp_json = decoded
                    break
                end
            else
                core.log.warn("Upstream call failed: ", err or "unknown")
            end
            ngx.sleep(1)
        end
    end

    if not last_resp or not last_resp.body then
        return 502, "Upstream response missing"
    end

    local decoded_body = core.json.decode(last_resp.body)
    if not decoded_body then
        return last_resp.status, "Invalid JSON from upstream"
    end

    if found then
        for key, value in pairs(last_resp.headers or {}) do
            local lower_key = string.lower(key)
            if lower_key ~= "transfer-encoding" and lower_key ~= "connection" then
                core.response.set_header(key, value)
            end
        end

        local body = core.request.get_body()
        local ok, input_body = pcall(core.json.decode, body)
        local input_address = (ok and input_body and input_body.address) or ""

        if decoded_body.result then
            for _, v in pairs(decoded_body.result) do
                local result_address = v.address or ""

                local inputAddressData, err1 = address_classification(input_address)
                local resultAddressData, err2 = address_classification(result_address)

                if type(inputAddressData) ~= "table" or type(resultAddressData) ~= "table" then
                    core.log.warn("Address classification failed: ", err1 or err2)
                    goto continue
                end

                local houseNumber = sanitize_string(inputAddressData.result.house_number or "")
                local locality = sanitize_string(inputAddressData.result.landmark or "")
                local area_type = sanitize_string(inputAddressData.result.area_type or "")

                local resultHouseNumber = sanitize_string(resultAddressData.result.house_number or "")
                local resultLocality = sanitize_string(resultAddressData.result.landmark or "")
                local resultAreaType = sanitize_string(resultAddressData.result.area_type or "")

                local houseScore = string_similarity(houseNumber, resultHouseNumber)
                local localityScore = string_similarity(locality, resultLocality)
                local areaTypeScore = string_similarity(area_type, resultAreaType)

                v.house_number = houseScore >= 90 and "EXACT_MATCH" or (houseScore >= 70 and "PARTIAL_FUZZY" or "NO_MATCH")
                v.landmark = localityScore >= 90 and "EXACT_MATCH" or (localityScore >= 70 and "PARTIAL_FUZZY" or "NO_MATCH")
                v.area_type = areaTypeScore >= 90 and "EXACT_MATCH" or (areaTypeScore >= 70 and "PARTIAL_FUZZY" or "NO_MATCH")
                if areaTypeScore >= 70 then
                    v.areaType = area_type
                end

                ::continue::
            end
        else
            core.log.warn("No result key found in response body")
        end

        deep_sanitize(decoded_body)
        return last_resp.status, core.json.encode(decoded_body)
    else
        deep_sanitize(decoded_body)
        return last_resp.status, core.json.encode(decoded_body)
    end
end

return _M
