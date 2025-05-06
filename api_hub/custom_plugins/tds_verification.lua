local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "tds_verification"

local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 2000,
    name = plugin_name,
    schema = schema,
}

local function is_in_list(value, list)
    if type(list) ~= "table" then
        return false
    end

    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_timestamp()
    local now = os.time()
    local micro = string.format("%.6f", ngx.now() % 1):sub(3)
    local tz = os.date("%z")
    return os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. micro .. tz
end

local function generate_transaction_id()
    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random.bytes(32)
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())
end

-- Define billable mapping from your table
local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },   
    [2]   = { code = 103, billable = "True",  message = "Invalid PAN Number" },
    [3]   = { code = 102, billable = "True",  message = "Invalid TAN Number" },
    [4]   = { code = 102, billable = "True",  message = "Invalid Financial Year" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Invalid ID number or combination of inputs" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [400] = { code = 110, billable = false, message = "Source Unavailable" },
    [401] = { code = 401, billable = false, message = "Bad credentials provided" },
    [402] = { code = 110, billable = false, message = "Source Unavailable" },
    [403] = { code = 110, billable = false, message = "Source Unavailable" },
    [404] = { code = 110, billable = false, message = "Source Unavailable" },
    [301] = { code = 110, billable = false, message = "Source Unavailable" },
    [302] = { code = 110, billable = false, message = "Source Unavailable" },
    [500] = { code = 110, billable = false, message = "Source Unavailable" },
    [502] = { code = 110, billable = false, message = "Source Unavailable" },
    [503] = { code = 110, billable = false, message = "Source Unavailable" },
    [504] = { code = 110, billable = false, message = "Source Unavailable" },

}


local success_status_code = {1,200,101}
local invalid_missing_status_code = {401,6,301,102,422,403}
local no_record_found_status_code = {2,4,3,4,103}

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
    ngx.ctx.request_timestamp = get_timestamp()-- Store request time in seconds
end

----Sorting response
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
        local data,err = new_json.decode(full_body)
        if data then
            core.log.warn("data_testing...........", new_json.encode(data),new_json.encode(err))
            -- return
        end
        
        -- local sourceMessage = data and  data['message'] or data['response_message']
        local result = {}
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
        local statusCode = data and data.status or  data.result_code
        local http_status = tonumber(statusCode) 
        -- Map source HTTP status to response code

        if is_in_list(http_status, success_status_code) then
            result["response_code"] = 101
        elseif is_in_list(http_status, invalid_missing_status_code) then
          
            result["response_code"] = 102
          
        elseif is_in_list(http_status, no_record_found_status_code) then
            result["response_code"] = 103
        else  
            result["response_code"] = 110
        end
        
        

        local billable_info = billable_dict[result["response_code"]] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }

        result["billable"] = billable_info.BILLABLE

        if billable_info.BILLABLE == "True" then
            result["success"] = "True"
        else 
            result["success"] = "False"
        end

        result["response_message"] = billable_info.MESSAGE

      
    
        result["request_timestamp"] = ngx.ctx.request_timestamp  
        result["response_timestamp"] = get_timestamp()
        result["result"] = data and data.result or  data.msg or {}
       
        
        if type(result["result"]) == "string" then
            result["result"] = "" 
        end

        -- Check for a specific key in the request headers
        ctx.var.isBulk = "API"
        local header_key = "x-trx-type" -- Replace with the desired header key
 --       core.log.warn("data bulk", new_json.encode(ngx.req.get_headers()))
        if ngx.req.get_headers()[header_key] then
            ctx.var.isBulk = ngx.req.get_headers()[header_key]
--            core.log.warn("data bulk", new_json.encode(ctx.var.isBulk))
        end
        
        local new_body = sorted_json(result)
        -- Set modified response and terminate further chunk processing
        ngx.arg[1] = new_body
        ngx.arg[2] = true
        
    end
end

return _M
