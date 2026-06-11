local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
 
local resty_random  = require("resty.random")
local ngx = ngx

local plugin_name = "sort_transform_response"

local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 2000,  -- High priority for modifying responses
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_timestamp()
    local now = os.time()
    local milliseconds = string.format("%.6f", ngx.now() % 1):sub(3) -- Get microseconds
    local timezone_offset = os.date("%z") -- Get timezone offset (e.g., +0530)
    local formatted_time = os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. milliseconds .. timezone_offset
    return formatted_time
end


-- Header modification block: Reset content-length
function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
    
end

 

local function generate_transaction_id()
   

    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random .bytes(32)  -- Generate 32 random bytes
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())  -- Return SHA-256 hash as hex string
end


local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },   
    [2] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [3] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [7] = { BILLABLE = "False", MESSAGE = "Number of PANs exceeds the limit (5)" },
    [8] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [11] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [12] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [13] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [16] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [99] = { BILLABLE = "False", MESSAGE = "Unknown Error" },
    [100] = { BILLABLE = "False", MESSAGE = "Internal Error" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Invalid ID number or combination of inputs" },
    [125] = { BILLABLE = "False", MESSAGE = "Missing name or address" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [105] = { BILLABLE = "True", MESSAGE = "Missing Consent" },
    [106] = { BILLABLE = "False", MESSAGE = "RC number is registered under more than one office" },
    [107] = { BILLABLE = "False", MESSAGE = "Invalid OTP" },
    [108] = { BILLABLE = "False", MESSAGE = "This is no longer active" },
    [109] = { BILLABLE = "False", MESSAGE = "Aadhaar suspended or cancelled. Please verify your Aadhaar at:https://resident.uidai.gov.in/verify " },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [403] = { BILLABLE = "False", MESSAGE = "Request limit exceeded" },
    [401] = { BILLABLE = "False", MESSAGE = "Unauthorized" }
}

local success_status_code = {1,200,101}
local invalid_missing_status_code = {401,301,3,102,422}
local invalid_missing_crime = {125}
local no_record_found_status_code = {2,4,103,404}

-- Function to check if value exists in a table
local function is_in_list(value, list)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

-- -- local source_unavaible_status_code = [1]
-- local function to_hex(str)

--     return (str:gsub('.', function(c)
--         return string.format('%02X', string.byte(c))
--     end))
-- end

-- Capture request start time
function _M.access(conf, ctx)
    ngx.req.set_header("Accept-Encoding", "identity")
    ngx.req.read_body()
    ngx.ctx.buffered_response = true
    ngx.ctx.request_timestamp = get_timestamp()-- Store request time in seconds
end


 

local function sorted_json(tbl)
    local function encode_value(v)
        local t = type(v)
        if t == "table" then
            return sorted_json(v)
        elseif t == "string" then
            return '"' .. v:gsub('"', '\\"') .. '"'
        elseif t == "boolean" or t == "number" then
            return tostring(v)
        else
            return 'null'
        end
    end

    local keys = {}
    for k in pairs(tbl) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local items = {}
    for _, k in ipairs(keys) do
        table.insert(items, '"' .. tostring(k) .. '":' .. encode_value(tbl[k]))
    end
    return '{' .. table.concat(items, ',') .. '}'
end


function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2] 

    -- Initialize response storage if not already set
    if not ngx.ctx.response_body then
        ngx.ctx.response_body = {}
    end

    -- Store incoming response chunks
    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.response_body, chunk)
        ngx.arg[1] = nil -- Prevent partial chunk output
    end

    if eof then
        -- Concatenate full response
        local full_body = table.concat(ngx.ctx.response_body)
        ctx.var.responseBodyFromSource = full_body

        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)
        local data, err = new_json.decode(full_body)
        local result = {}

        -- Handle JSON decode error
        if not data then
            result["response_code"] = 101
            result["response_message"] = "Internal Error: Invalid JSON response"
            result["billable"] = "False"
            result["success"] = "False"
            result["result"] = {}
            result["request_timestamp"] = ngx.ctx.request_timestamp
            result["response_timestamp"] = get_timestamp()
            ngx.arg[1] = sorted_json(result)
            ngx.arg[2] = true
            return
        end

        if ngx.status == 401 then
            result["response_code"] = 401
            result["response_message"] = "Bad credentials provided"
            local new_bodys = new_json.encode(result)
            ngx.arg[1] = new_bodys
            ngx.arg[2] = true
            return
        elseif ngx.status == 403 then
            result["response_code"] = 403
            result["response_message"] = "Access Denied"
            local new_bodys = new_json.encode(result)
            ngx.arg[1] = new_bodys
            ngx.arg[2] = true
            return
        elseif ngx.status == 429 then
            result["response_code"] = 429
            result["response_message"] = "Limit exceeds , Too many requests"
            local new_bodys = new_json.encode(result)
            ngx.arg[1] = new_bodys
            ngx.arg[2] = true
            return
        end

        local request_body = ngx.req.get_body_data()
        local input_data = request_body and pcall(json.decode, request_body) and json.decode(request_body) or {}
        if input_data["consent_text"] ~= nil then
            input_data["consent_text"] = nil
        end
        if input_data["consent"] ~= nil then
            input_data["consent"] = nil
        end
        result["input"] = input_data
        result["transaction_id"] = generate_transaction_id()

        local statusCode = data and (
            data.status
            or data.statusCode
            or data.result_code
            or data.response_code
            or (type(data.result) == "table" and data.result.status_code)
            or (type(data.error) == "table" and data.error.statusCode)
        )
        local http_status = tonumber(statusCode)
        if is_in_list(http_status, success_status_code) then
            result["response_code"] = 101
        elseif is_in_list(http_status, invalid_missing_status_code) then
            result["response_code"] = 102
        elseif is_in_list(http_status, invalid_missing_crime) then
            result["response_code"] = 125
        elseif is_in_list(http_status, no_record_found_status_code) then
            result["response_code"] = 103
        else
            result["response_code"] = 110
        end

        local billable_info = billable_dict[result["response_code"]] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }
        result["billable"] = billable_info.BILLABLE
        result["success"] = billable_info.BILLABLE == "True" and "True" or "False"
        result["response_message"] = billable_info.MESSAGE
        result["request_timestamp"] = ngx.ctx.request_timestamp
        result["response_timestamp"] = get_timestamp()
        core.log.warn("data bulk", new_json.encode(data))

        if result["response_code"] == 125 then
            result["response_code"] = 102
            result["response_message"] = "Missing name or address"
        end

        result["result"] = data and data.result or data.msg or data.data or {}
        if type(result["result"]) == "string" then
            result["result"] = ""
        end

        ctx.var.isBulk = "API"
        local header_key = "x-trx-type"
        if ngx.req.get_headers()[header_key] then
            ctx.var.isBulk = ngx.req.get_headers()[header_key]
        end

        ctx.var.isLogIn_id = 0
        local header_key_login = "x-login-id"
        if ngx.req.get_headers()[header_key_login] then
            ctx.var.isLogIn_id = ngx.req.get_headers()[header_key_login]
        end
        core.log.warn("data uiianilllllllllllbulk", new_json.encode(result))

        local new_body = sorted_json(result)
        ngx.arg[1] = new_body
        ngx.arg[2] = true
    end
