local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "crime_search_id"

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
    -- [2]   = { code = 102, billable = "True",  message = "Invalid PAN Number" },
    -- [3]   = { code = 102, billable = "True",  message = "Invalid TAN Number" },
    -- [4]   = { code = 102, billable = "True",  message = "Invalid Financial Year" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Missing name or father_name" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [400] = { code = 102, billable = false, message = "Parameter Missing" },
    [401] = { code = 401, billable = false, message = "Bad credentials provided" },
    [402] = { code = 110, billable = false, message = "Source Unavailable" },
    [403] = { code = 110, billable = false, message = "Source Unavailable" },
    [404] = { code = 110, billable = false, message = "Source Unavailable" },
    -- [301] = { code = 110, billable = false, message = "Source Unavailable" },
    [422] = { BILLABLE = "False", MESSAGE = "Parameter Missing" },
    [302] = { code = 110, billable = false, message = "Source Unavailable" },
    [500] = { code = 110, billable = false, message = "Source Unavailable" },
    [502] = { code = 110, billable = false, message = "Source Unavailable" },
    [503] = { code = 110, billable = false, message = "Source Unavailable" },
    [504] = { code = 110, billable = false, message = "Source Unavailable" },

}


local success_status_code = {1,200,101}
local invalid_missing_status_code = {400,5,0,422}
local no_record_found_status_code = {103}
local parameter_missing_status_code ={422}


-- Capture request start time
function _M.access(conf, ctx)
    ngx.ctx.request_timestamp = get_timestamp()-- Store request time in seconds
end

local function sorted_json(tbl, key_order)
    local function encode_value(v)
        local t = type(v)
        if t == "table" then
            return sorted_json(v)  -- nested tables still get sorted alphabetically
        elseif t == "string" then
            return '"' .. v:gsub('"', '\\"') .. '"'
        elseif t == "boolean" or t == "number" then
            return tostring(v)
        else
            return 'null'
        end
    end

    local items = {}

    -- Add keys from custom order first
    if key_order then
        for _, k in ipairs(key_order) do
            if tbl[k] ~= nil then
                table.insert(items, '"' .. k .. '":' .. encode_value(tbl[k]))
            end
        end
    end

    -- Add remaining keys not in custom order (sorted)
    local remaining_keys = {}
    local order_lookup = {}
    for _, k in ipairs(key_order or {}) do
        order_lookup[k] = true
    end

    for k in pairs(tbl) do
        if not order_lookup[k] then
            table.insert(remaining_keys, k)
        end
    end

    table.sort(remaining_keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(remaining_keys) do
        table.insert(items, '"' .. tostring(k) .. '":' .. encode_value(tbl[k]))
    end

    return '{' .. table.concat(items, ',') .. '}'
end


local key_order = {
    "transaction_id",
    "input",
    "success",
    "billable",
    "response_code",
    "response_message",
    "result",
    "request_timestamp",
    "response_timestamp"
}




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
        core.log.error("SANJAY------------: ", core.json.encode(statdatausCode))  

   
        -- if data then
        --  --   core.log.warn("kumar yadava-----------........................", new_json.encode(data),new_json.encode(err))
        --     -- return
        -- end



        
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

        -- elseif ngx.status == 422 then  -- Handling 422 status code for parameter validation
        --     result["response_code"] = 422
        --     result["response_message"] = "Parameter Missing"
        --      local new_bodys = new_json.encode(result)

        --     ngx.arg[1] = new_bodys
        --     ngx.arg[2] = true
        --     return


      
        -- elseif ngx.status == 422 then  -- Handling 422 status code for parameter validation
        --      result["response_code"] = 422
        --      result["response_message"] = "Parameter Missing"
        --      local new_bodys = new_json.encode(result)

        --      ngx.arg[1] = new_bodys
        --      ngx.arg[2] = true
        --      return


        elseif ngx.status == 429 then 
            result["response_code"] = 429
            result["response_message"] = "Limit exceeds , Too many requests"
            local new_bodys = new_json.encode(result)
  
        
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
         if data and data.cs_id then
                local cs_id_str = tostring(data.cs_id) -- Ensure it's a string for trimming
                -- Trim whitespace from the string
                local trimmed_cs_id = cs_id_str:match("^%s*(.-)%s*$")

                -- Check if the trimmed string is not empty
                if trimmed_cs_id ~= "" then
                    result["transaction_id"] = trimmed_cs_id
                else
                    -- If cs_id exists but is empty or only whitespace after trimming
                    result["transaction_id"] = generate_transaction_id()
                end
            else
                -- If 'data' is nil, or 'data.cs_id' is nil
                result["transaction_id"] = generate_transaction_id()
            end
                    
            


        -- result["transaction_id"] =generate_transaction_id()



        -- result["transaction_id"] = generate_transaction_id()
        
        
        -- Get HTTP status from the response
        local statusCode = data and data.status or  data.result_code
        local http_status = tonumber(statusCode) 
        -- Map source HTTP status to response code
        if data.status==102 then
          result["response_code"] = 102
        elseif data.status==125 then
            result["response_code"] = 125
        elseif is_in_list(http_status, success_status_code) then
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
        result["success"] = billable_info.BILLABLE == "True" and "True" or "False"

        if not result["response_message"] then
            result["response_message"] = billable_info.MESSAGE
        end
        
       
        result["request_timestamp"] = ngx.ctx.request_timestamp  
        result["response_timestamp"] = get_timestamp()

      
         if data and data.cs_id then
            result["result"] = result["result"] or {}
            result["result"]["task_id"] = data.cs_id
        else
            result["result"] = data and data.error or {}
        end
        


        -- result["result"] = data and data.cs_id or data.error or {}
       
        
        -- Check for a specific key in the request headers
        ctx.var.isBulk = "API"
        local header_key = "x-trx-type"  
        if ngx.req.get_headers()[header_key] then
            ctx.var.isBulk = ngx.req.get_headers()[header_key]
        end
        
        -- Check for a specific key in the request headers
  

        ctx.var.isLogIn_id = 0
        local header_key_login = "x-login-id"
        local headers = ngx.req.get_headers()

        if headers[header_key_login] then
            ctx.var.isLogIn_id = headers[header_key_login]
        end

        -- Ensure result["result"] is not a string
        -- if type(result["result"]) == "string" then
        --     result["result"] = ""
        -- end

        -- Convert the Lua table to a JSON string
        local new_body_str =sorted_json(result)

        -- Replace the response body with the modified JSON string
        ngx.arg[1] = new_body_str
        ngx.arg[2] = true  -- true means this is the last chunk

    end
end

return _M
