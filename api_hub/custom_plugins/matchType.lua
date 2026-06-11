local core = require("apisix.core")
local plugin_name = "match_score_evaluator"
local json = require("cjson.safe")

 

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 1900,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
    
end






local function escape_backslashes(tbl)
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            escape_backslashes(v)
        elseif type(v) == "string" then
            tbl[k] = v:gsub("\\", "\\\\"):gsub("[\r\n]", " ")
        end
    end
end

local function sorted_json(tbl)
    if type(tbl) ~= "table" then
        return "{}"
    end

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

    table.sort(keys, function(a, b)
        if type(a) == "number" and type(b) == "number" then
            return a < b
        elseif type(a) == "string" and type(b) == "string" then
            return tostring(a) < tostring(b)
        else
            return false
        end
    end)

    local items = {}
    for _, k in ipairs(keys) do
        table.insert(items, '"' .. tostring(k) .. '":' .. encode_value(tbl[k]))
    end
    return '{' .. table.concat(items, ',') .. '}'
end


function _M.access(conf, ctx)
    core.log.warn("JSON decoding after everything 2000")
    ngx.req.set_header("Accept-Encoding", "identity")
    ngx.req.read_body()
    ngx.ctx.buffered_response = true
     
end

-- Function to calculate points based on match type
local function calculate_points(match_type, match_type2)
    if match_type2 == 4 then
        if match_type == "EXACT_MATCH" or match_type == "MATCH" then
            return 4
        elseif match_type == "PARTIAL_FUZZY" or  match_type ==""then
            return 2
        elseif match_type == "NO_MATCH" or match_type == "NOT_MATCH" then
            return -4
        end
    elseif match_type2 == 2 then
        if match_type == "EXACT_MATCH" or match_type == "MATCH" then
            return 2
        elseif match_type == "PARTIAL_FUZZY" then
            return 1
        elseif match_type == "NO_MATCH" or match_type == "NOT_MATCH" then
            return -1
        end
    elseif match_type2 == "rural" then
        if match_type == "EXACT_MATCH" or match_type == "MATCH" then
            return 2
        elseif match_type == "PARTIAL_FUZZY" then
            return 1
        elseif match_type == "NO_MATCH" or match_type == "NOT_MATCH" then
            return -1
        end
    elseif match_type2 == "urban" then
        if match_type == "EXACT_MATCH" or match_type == "MATCH" then
            return 1
        elseif match_type == "PARTIAL_FUZZY" then
            return 1
        elseif match_type == "NO_MATCH" or match_type == "NOT_MATCH" then
            return -1
        end
    end
    return 0
end




function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2] 
     
    if not ngx.ctx.responseDatas then
        ngx.ctx.responseDatas = {}
    end

    -- Store incoming response chunks
    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.responseDatas, chunk)
        ngx.arg[1] = nil -- Prevent partial chunk output
    end

    if eof then
        local full_body = table.concat(ngx.ctx.responseDatas)      

        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)
        local body,err = new_json.decode(full_body)

 
        local result = {}
        if not body then
            result["response_code"] = 110
            result["response_message"] = "Source unavailable"
            result["result"] = {}
            local new_bodys = new_json.encode(result)
        
            -- Set modified response and terminate further chunk processing
            ngx.arg[1] = new_bodys
            ngx.arg[2] = true
            return
        end
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



        local old_result = body.result
        local new_result = {}

        for _, value in pairs(old_result) do
            table.insert(new_result, value)
        end

        body.result = new_result or {}
        local inputData = body.input or {}
        inputData.source = nil
        inputData.user = nil
        inputData.auth_token = nil
        body.input = inputData
        




        -- father_match_type  key from source  PARTIAL_EXACT

        for _, obj in pairs(body.result) do
            if type(obj) == "table" then
                local total_score = 0
                local fatherName = obj.father_name or ""
                 

                if fatherName ~= "" then
                    total_score = total_score + calculate_points(obj.father_match_type,4)
                end
                
                total_score = total_score + calculate_points(obj.name_match_type,4)
                total_score = total_score + calculate_points(obj.area_type,obj.areaType)
                total_score = total_score + calculate_points(obj.house_number,4)
                total_score = total_score + calculate_points(obj.landmark,2)
                obj.source = nil
                obj.link = nil
                obj.order_link = nil
                if total_score >= 11 then
                    obj.overall_match = "EXACT_MATCH"
                elseif total_score >= 3 and total_score < 11 then
                    obj.overall_match = "PARTIAL_MATCH"
                elseif total_score < 3 then
                    obj.overall_match = "NO_MATCH"
                end
            end
        end
        
        -- Filter out objects with overall_match == "NO_MATCH"
        if body and body.result and type(body.result) == "table" then
            local filtered = {}
            for _, obj in pairs(body.result) do
                if obj.overall_match == "EXACT_MATCH" or obj.overall_match == "PARTIAL_MATCH" then
                    obj.landmark = nil
                    obj.area_type = nil
                    obj.house_number = nil
                    table.insert(filtered, obj)
                end
            end
            body.result = filtered
        end
        
     


   if type(body) == "table" then
        local transformData_str = sorted_json(body)
        local transformData = json.decode(transformData_str)

    if transformData and
        tostring(transformData.response_code) == "101" and
        type(transformData.result) == "table" and
        next(transformData.result) == nil then

        transformData.response_code = 103
        transformData.response_message = "No records found for the given ID or combination of inputs"
        core.log.warn("✅ Condition matched and modified")

        else
            core.log.warn("❌ Condition NOT matched", json.encode(transformData))
        end

    escape_backslashes(transformData)
    ngx.arg[1] = sorted_json(transformData)

    else
        core.log.warn("❌ Invalid body: expected table, got " .. type(body))
        ngx.arg[1] = "{}"
    end

       
        ngx.arg[2] = true
        
    end
end

return _M
