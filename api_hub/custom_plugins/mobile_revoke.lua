local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "mobile_revoke"

local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 1800,
    name = plugin_name,
    schema = schema
}


function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if not ngx.ctx.responseBody then
        ngx.ctx.responseBody = {}
    end

    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.responseBody, chunk)
        ngx.arg[1] = nil
    end




   

  
    if eof then
        local full_body = table.concat(ngx.ctx.responseBody)
        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)
        local data = new_json.decode(full_body)
         
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

        end
         
        local original_result = data  

        original_result["result"] = {
            date_of_revoke = original_result.result.revoke_date,
            status_of_revoke = original_result.result.revoke_status
        }

        ngx.arg[1] = new_json.encode(original_result)
        ngx.arg[2] = true
    end
end

return _M