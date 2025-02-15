local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
 
local resty_random  = require("resty.random")
local ngx = ngx

local plugin_name = "transform_response"

local schema = { type = "object", properties = {} }

local _M = {
    version = 0.1,
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

 

-- Modify response body
-- local json = require "cjson.safe"

local function generate_transaction_id()
   

    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random .bytes(32)  -- Generate 32 random bytes
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())  -- Return SHA-256 hash as hex string
end

local response_code_map = {
    [200] = 101,
    [400] = 102,
    [503] = 110
}

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
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [105] = { BILLABLE = "True", MESSAGE = "Missing Consent" },
    [106] = { BILLABLE = "False", MESSAGE = "RC number is registered under more than one office" },
    [107] = { BILLABLE = "False", MESSAGE = "Invalid OTP" },
    [108] = { BILLABLE = "False", MESSAGE = "This is no longer active" },
    [109] = { BILLABLE = "False", MESSAGE = "Aadhaar suspended or cancelled. Please verify your Aadhaar at:https://resident.uidai.gov.in/verify " },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" }
}

-- Capture request start time
function _M.access(conf, ctx)
    ngx.ctx.request_timestamp = get_timestamp()-- Store request time in seconds
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
        local data,err = new_json.decode(full_body)
        if not data then
            core.log.warn("JSON decoding failed: ", success)
            return
        end
        
        local sourceMessage = data['message']
        local result = { }
        local request_body = ngx.req.get_body_data()
        local input_data = request_body and pcall(json.decode, request_body) and json.decode(request_body) or {}
        result["input"] = input_data

        -- Generate and add a unique transaction ID
        result["transaction_id"] = generate_transaction_id()

        -- Get HTTP status from the response
        local http_status = ngx.status  -- Get the HTTP status code from Nginx

        -- Map source HTTP status to response code
        if http_status == 200 and sourceMessage == "No record found" then
            result["response_code"] = 103
        else
            result["response_code"] = response_code_map[http_status] or 999 -- Default to 999 if unknown status
        end

        local billable_info = billable_dict[result["response_code"]] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }

        result['billable'] = billable_info.BILLABLE
        result['message'] = billable_info.MESSAGE
        result["request_timestamp"] = ngx.ctx.request_timestamp  
        result["response_timestamp"] = get_timestamp()
        result['result'] = data.result 

        -- Encode modified response
        local new_body = new_json.encode(result)

        -- Set modified response and terminate further chunk processing
        ngx.arg[1] = new_body
        ngx.arg[2] = true  -- Mark response as fully processed
    end
end


return _M
