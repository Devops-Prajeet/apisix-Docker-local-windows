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
    local new_json = json.new()
    new_json.encode_sparse_array(true, 1, 1)
    ctx.var.responseFromHeader = ngx.resp.get_headers()['x-signzy-trace-id']
    
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


-- local billable_dict = {
--     [1] = { BILLABLE = "True", MESSAGE = "Success" },   
--     [2] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [3] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [7] = { BILLABLE = "False", MESSAGE = "Number of PANs exceeds the limit (5)" },
--     [8] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [11] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [12] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [13] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [16] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
--     [99] = { BILLABLE = "False", MESSAGE = "Unknown Error" },
--     [100] = { BILLABLE = "False", MESSAGE = "Internal Error" },
--     [101] = { BILLABLE = "True", MESSAGE = "Success" },
--     [102] = { BILLABLE = "False", MESSAGE = "Invalid ID number or combination of inputs" },
--     [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
--     [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
--     [105] = { BILLABLE = "True", MESSAGE = "Missing Consent" },
--     [106] = { BILLABLE = "False", MESSAGE = "RC number is registered under more than one office" },
--     [107] = { BILLABLE = "False", MESSAGE = "Invalid OTP" },
--     [108] = { BILLABLE = "False", MESSAGE = "This is no longer active" },
--     [109] = { BILLABLE = "False", MESSAGE = "Aadhaar suspended or cancelled. Please verify your Aadhaar at:https://resident.uidai.gov.in/verify " },
--     [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
--     [403] = { BILLABLE = "False", MESSAGE = "Request limit exceeded" },
--     [401] = { BILLABLE = "False", MESSAGE = "Unauthorized" }
-- }



local billable_dict = {
    ["TB000"] = { statusCode = "TXN" ,BILLABLE = "True", MESSAGE = "Account details successfully verified", remark = "Transaction Successful"},   
    ["TB001"] = { statusCode = "IAN",BILLABLE = "True",MESSAGE= "Invalid Account Number",remark = "Invalid Account Number" }, 
    ["TB402"] = { statusCode = "FAB",BILLABLE = "False" ,MESSAGE= "Failure at Bank end",remark = "Failure at Bank end"}, 
    ["TB005"] = { statusCode = "IAN" ,BILLABLE = "True",MESSAGE= "Invalid Account Number",remark = "Invalid Account Number"}, 
    ["TB006"] = { statusCode = "IAN" ,BILLABLE = "True",MESSAGE= "Invalid Account Number",remark = "Invalid Account Number"}, 
    ["TB008"] = { statusCode = "TUP" ,BILLABLE = "True",MESSAGE= "Transaction under Process",remark = "Transaction under process"}, 
    ["TB301"] = { statusCode = "TUP" ,BILLABLE = "True",MESSAGE= "Transaction under Process",remark = "Transaction under process"}, 
    ["TB302"] = { statusCode = "TUP" ,BILLABLE = "True",MESSAGE= "Transaction under Process",remark = "Transaction under process"}, 
    ["TB401"] = { statusCode = "UNE",BILLABLE = "False" ,MESSAGE= "Unknown Error",remark = "Unknown Error"},
    ["TB101"] = { statusCode = "IE" ,BILLABLE = "False",MESSAGE= "Internal Error",remark = "Internal Error"},
    ["TB007"] = { statusCode = "IAN" ,BILLABLE = "True",MESSAGE= "Invalid Account Number",remark = "Invalid Account Number"}, 
    ["TB102"] = { statusCode = "IAN" ,BILLABLE = "True",MESSAGE= "Invalid Account Number",remark = "Invalid Account Number"}, 
    ["TB009"] = { statusCode = "SUA",BILLABLE = "False",MESSAGE= "Service Unavailable" ,remark = "Transaction Successful"}   
}

-- Function to check if value exists in a table
local function is_in_list(value, list)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

-- Capture request start time
function _M.access(conf, ctx)
    ngx.req.set_header("Accept-Encoding", "identity")
    ngx.req.read_body()
    ngx.ctx.buffered_response = true
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
           
        local full_body = table.concat(ngx.ctx.response_body)      

        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)
        local data,err = new_json.decode(full_body)
         
        full_body = new_json.decode(full_body)
        -- if ctx.var.responseFromHeader then 
        --     full_body.x_trx_id = ctx.var.responseFromHeader
        -- end

        ctx.var.responseBodyFromSource = new_json.encode(full_body)
        if data then
            core.log.warn("testing for api chaiingin" ,new_json.encode(full_body))
            -- return
        end
        
        -- local sourceMessage = data and  data['message'] or data['response_message'] -----------------------------------
        local result = { }
        if ngx.status == 401 then
            result["response_code"] = 401
            result["response_message"] = "Bad credentials provided"
            local new_bodys = new_json.encode(result)
        
            -- Set modified response and terminate further chunk processing
            ngx.arg[1] = new_bodys
            ngx.arg[2] = true
            
            return
            
        elseif ngx.status == 403 then 
            result["response_code"] = 403
            result["response_message"] = "Access Denied"
            local new_bodys = new_json.encode(result)
        
            -- Set modified response and terminate further chunk processing
            ngx.arg[1] = new_bodys
            ngx.arg[2] = true
            return

         elseif ngx.status == 429 then 
            result["response_code"] = 429
            result["response_message"] = "Limit exceeds , Too many requests"
            local new_bodys = new_json.encode(result)
            --core.log.warn("DATA---------------------------------------------------------",new_bodys)
        
            -- Set modified response and terminate further chunk processing
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

        -- Generate and add a unique transaction ID
        result["transaction_id"] = generate_transaction_id()
        
        
        -- Get HTTP status from the response
        local statusCode = data and (
                        data.statusCode
                         
                    )
         
        
        

        local billable_info = billable_dict[statusCode] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }

        result["billable"] = billable_info.BILLABLE
        result["response_code"] = billable_info.statusCode
        result["response_message"] = billable_info.MESSAGE

        if billable_info.BILLABLE == "True" then
            result["success"] = "True"
        else 
            result["success"] = "False"
        end

        
        result["request_timestamp"] = ngx.ctx.request_timestamp  
        result["response_timestamp"] = get_timestamp()
        result["result"] =  {
            result_name = data.nameAtBank,
            result_bank_ref = data.utr,
            result_remark = billable_info.remark,
            result_status = data.acValidationStatus
             
        }
       
        
        -- if type(result["result"]) == "string" then
        --     result["result"] = "" 
        -- end

        -- Check for a specific key in the request headers
        ctx.var.isBulk = "API"
        local header_key = "x-trx-type"  
        if ngx.req.get_headers()[header_key] then
            ctx.var.isBulk = ngx.req.get_headers()[header_key]
        end


        -- Check for a specific key in the request headers
        ctx.var.isLogIn_id = 0
        local header_key_login = "x-login-id"  
        if ngx.req.get_headers()[header_key_login] then
            ctx.var.isLogIn_id = ngx.req.get_headers()[header_key_login]
        end
        
        local new_body = new_json.encode(result)
        -- Set modified response and terminate further chunk processing
        ngx.arg[1] = new_body
        ngx.arg[2] = true
        
    end
end

return _M