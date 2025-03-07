-- check_request_body.lua
local core = require("apisix.core")
local json = require("cjson")

local plugin_name = "pan_aadhar"

local _M = {
    version = 0.1,
    priority = 1500,  -- Adjust priority as needed
    name = plugin_name,
}

-- Define the schema inside the same file
_M.schema = {
    type = "object",
    properties = {
        -- Define the two required keys
        required_key_1 = {
            type = "string",
            minLength = 1,  -- Ensure the key name is non-empty
        },
        required_key_2 = {
            type = "string",
            minLength = 1,  -- Ensure the key name is non-empty
        },
    },
    required = {},  -- No required fields; the default values will be handled in the plugin code
}

-- function _M.check_schema(conf)
--     return core.schema.check(schema, conf)
-- end

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
end

-- The logic to check the request body
-- function _M.check_body(ctx, required_key_1, required_key_2)
--     ngx.req.read_body()
--     local body = ngx.req.get_body_data()
     

--     -- If there is no request body, return an error
--     if not body then
--         return 400, { message = "Request body is missing" }
--     end

--     local ok, json_body = pcall(json.decode, body)
--     if not ok then
--         return 400, { message = "Invalid JSON in request body" }
--     end

--     -- Check for the first required key in the body
--     if not json_body[required_key_1] then
--         return 400, { message = "Missing " .. required_key_1 .. " in the request body" }
--     end

--     -- Check for the second required key in the body
--     if not json_body[required_key_2] then
--         return 400, { message = "Missing " .. required_key_2 .. " in the request body" }
--     end

--     -- If both keys exist, allow the request to continue
--     return 200
-- end

-- The access phase where the body check happens
-- function _M.access(conf, ctx)
--     -- Set default values for required_key_1 and required_key_2 if not provided in the configuration
--     -- Use default values for the `required_key_1` and `required_key_2` if not provided by the user
--     local required_key_1 = "pan"
--     local required_key_2 = "aadhaar"

--     -- Check the request body for both keys
--     local status, response = _M.check_body(ctx, required_key_1, required_key_2)
    
--     if status ~= 200 then
--         return core.response.exit(status, response)
--     end
-- end


 

function is_blank(value)
    return value == nil or value:match("^%s*$")  -- Checks for nil or strings with only whitespace
end

function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2]

    -- Initialize response storage if not already set
    if not ngx.ctx.response_SBI then
        ngx.ctx.response_SBI = {}
    end

    -- Store incoming response chunks
    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.response_SBI, chunk)
        ngx.arg[1] = nil -- Prevent partial chunk output
    end

    if eof then
        -- Concatenate full response
        local full_body = table.concat(ngx.ctx.response_SBI)
        ctx.var.responseBodyFromSBI = full_body

        -- Decode the JSON response from source
        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)
        local data, err = new_json.decode(full_body)


        
        if err then
            core.log.error("Failed to decode response body: ", err)
            return
        end


        -- if ngx.status == 400 then 
             
        --     local new_bodys = new_json.encode(data)
        --     -- Set modified response and terminate further chunk processing
        --     ngx.arg[1] = new_bodys
        --     ngx.arg[2] = true
        --     return

        -- end
        
        -- Get the masked Aadhaar number from the response
        local masked_aadhaar = data.result and data.result.aadhaar

        local notResult = data.result or ""

        -- Check if we have a valid masked Aadhaar
        -- if not masked_aadhaar then
        --     core.log.warn("Masked Aadhaar not found in the response body",masked_aadhaar,)
        --     return
        -- end
        local result = { }
        result['masked_aadhaar'] =  ""
        result['pan_adhr_link_status'] = ""


        -- if is_blank(notResult) then
        --    result['pan_adhr_link_status'] = "NOT FOUND"

        local statusCode = tonumber(data.response_code)
        if  statusCode == 102 then
            result['pan_adhr_link_status'] = "INVALID PAN"
        elseif  statusCode == 103 then
            result['pan_adhr_link_status'] = "NULL"
        elseif  statusCode == 110 then
            result['pan_adhr_link_status'] = "ERROR"
        elseif is_blank(masked_aadhaar) then
            result['pan_adhr_link_status'] = "NOT SEEDED"
        else
            local request_body = ngx.req.get_body_data()
            local request_data = json.decode(request_body)
            local last_four_digits = request_data and request_data.aadhaar
    
            if not last_four_digits or #last_four_digits ~= 4 then
                core.log.error("Invalid last four digits of Aadhaar in request body")
                return
            end
    
            -- Masked Aadhaar usually follows a format like "XXXX-XXXX-1234"
            local last_four_from_masked = masked_aadhaar:sub(-4)
    
            -- Compare the last four digits from the masked Aadhaar with the request body
             
            if last_four_from_masked == last_four_digits then
                result['masked_aadhaar'] = masked_aadhaar
                result['pan_adhr_link_status'] = "YES"
            else 
               result['masked_aadhaar'] = masked_aadhaar
               result['pan_adhr_link_status'] = "NO" 
            end
    
            -- Update the response body with modified data if necessary
            
            
        end

        -- local responseData = {
        --     result = result
        -- }

        data['result'] = result

        -- Extract the last four digits from the request body
        local new_body = new_json.encode(data)
        -- Set the modified response and terminate further chunk processing
        ngx.arg[1] = new_body
          
    end
end

return _M
