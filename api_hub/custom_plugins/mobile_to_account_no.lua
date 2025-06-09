local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")

local plugin_name = "mobile_to_account_no"
local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 1999,
    name = plugin_name,
    schema = schema
}

local billable_dict = {
    [1]   = { code = 101, message = "Success", billable = "True" },
    [2]   = { code = 103, message = "No Record Found", billable = "True" },
    [3]   = { code = 102, message = "Invalid ID number or combination of inputs", billable = "False" },
    [4]   = { code = 103, message = "No Response from Beneficiary Bank", billable = "True" },
    [5]   = { code = 103, message = "Transaction Not Permitted to the Account", billable = "True" },
    [6]   = { code = 103, message = "No Digital Payment Id generated", billable = "True" },
    [7]   = { code = 103, message = "Suspected Fraud", billable = "True" },
    [8]   = { code = 103, message = "Digital Payment Id Inactive", billable = "True" },
    [9]   = { code = 103, message = "Transaction not Permitted to the Digital Payment Id by the PSP", billable = "True" },
    [10]  = { code = 103, message = "No Digital Payment Id Found", billable = "True" },
    [101] = { billable = "True", message = "Success" },
    [102] = { billable = "False", message = "Invalid ID number or combination of inputs" },
  --  [103] = { billable = "True", message = "No records found for the given ID or combination of inputs" },
    -- [103] = { billable = "True", message = "Anil kumar-----------" },
    -- [104] = { billable = "True", message = "Max retries exceeded" },
    [400] = { code = 102, message = "Invalid ID number or combination of inputs" },
    [401] = { code = 401, message = "Authkey missing- or invalid", billable = "False" },
    [402] = { code = 402, message = "Your account does not have the required privilege to access this API", billable = "False" },
    [403] = { code = 403, message = "Request limit exceeded", billable = "False" },
    [404] = { code = 404, message = "IP Address not whitelisted", billable = "False" },
    [301] = { code = 102, message = "Parameter missing / Consent missing or invalid", billable = "False" },
    [302] = { code = 110, message = "Source down", billable = "False" }
}


local success_status_code = {1, 200, 101}
local invalid_missing_status_code = {102, 422}
local source_down_status = {401, 402, 403, 301, 302, 404}
local no_record_found_status_code = {2, 3, 4, 5, 6, 7, 8, 9, 10, 103, 400}


-- Function to check if value exists in a table
local function is_in_list(value, list)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end


local function generate_transaction_id()
    local random_bytes = resty_random.bytes(16)
    local sha256 = resty_sha256:new()
    sha256:update(random_bytes)
    return str.to_hex(sha256:final())
end

local function get_timestamp()
    local now = os.time()
    local milliseconds = string.format("%.6f", ngx.now() % 1):sub(3) -- Get microseconds
    local timezone_offset = os.date("%z") -- Get timezone offset (e.g., +0530)
    local formatted_time = os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. milliseconds .. timezone_offset
    return formatted_time
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


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.access(conf, ctx)
    ngx.req.read_body()
    ngx.ctx.buffered_response = true
    ngx.ctx.request_timestamp = get_timestamp()
end

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
end


function _M.body_filter(conf, ctx)
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
        ctx.var.responseBodyFromSource = full_body

        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)
        local data,err = new_json.decode(full_body)
        if data then
            core.log.warn("Sonika Sharma...........", new_json.encode(data),new_json.encode(err))
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
        -- local statusCode = data and data.status or  data.result_code
       -- local statusCode = tonumber(data and data.status or data.result_code) or ngx.status
        local http_status = tonumber(data.status) 
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
        
        local billable_info = billable_dict[result["response_code"]] or { billable = "False", message = "Unknown Response Code" }
        -- local billable = billable_dict[tonumber(result["response_code"])] or { billable = "False", message = "Unknown Response Code" }

        result["billable"] = billable_info.billable

        if billable_info.billable == "True" then
            result["success"] = "True"
        else 
            result["success"] = "False"
        end

        result["response_message"] = billable_info.message


        result["request_timestamp"] = ngx.ctx.request_timestamp  
        result["response_timestamp"] = get_timestamp()
        result["result"] = data and data.result or  data.msg or {}



        if data and result.response_code == 103 then
            if type(data.message) == "string" then
                if data.message:find("Digital Payment Id Inactive", 1, true) then
                    result.response_message = "Digital Payment Id Inactive"
                elseif data.message:find("No Digital Payment Id Found", 1, true) then
                    result.response_message = "No Digital Payment Id Found"
                elseif data.message:find("No Digital Payment Id generated", 1, true) then
                    result.response_message = "No Digital Payment Id generated"
                elseif data.message:find("Transaction Not Permitted to the Account", 1, true) then
                    result.response_message = "Transaction Not Permitted to the Account"
                elseif data.message:find("Suspected Fraud", 1, true) then
                    result.response_message = "Suspected Fraud"
                elseif data.message:find("Transaction not Permitted to the Digital Payment Id by the PSP", 1, true) then
                    result.response_message = "Transaction not Permitted to the Digital Payment Id by the PSP"
                elseif data.message:find("No Record Found", 1, true) then
                    result.response_message = "No Record Found"
                elseif data.message:find("No Response from Beneficiary Bank", 1, true) then
                    result.response_message = "No Response from Beneficiary Bank"
                else
                    result.response_message = "No records found for the given ID or combination of inputs"
                end
            else
                result.response_message = "No records found for the given ID or combination of inputs"
            end
        end
        
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
        
        if type(result["result"]) == "string" then
            result["result"] = "" 
        end

        ngx.arg[1] = sorted_json(result)
        ngx.arg[2] = true
    end
end

return _M





