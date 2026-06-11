--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core   = require("apisix.core")
local http   = require("resty.http")
local string = string
local pairs  = pairs
local cjson  = require("cjson.safe")
local ngx    = ngx
-- local ngx = require "ngx.re"


local plugin_schema = {
    type = "object",
    properties = {
        nodes = {
            type = "array",
            minItems = 1,
            items = {
                type = "object",
                properties = {
                    url = {
                        type = "string",
                        minLength = 1
                    },
                    ssl_verify = {
                        type = "boolean",
                        default = false,
                    },
                    timeout = {
                        type = "integer",
                        minimum = 1,
                        maximum = 6000000,
                        default = 60000,
                        description = "timeout in milliseconds",
                    },
                    keepalive = {type = "boolean", default = true},
                    keepalive_timeout = {type = "integer", minimum = 1000, default = 600000},
                    keepalive_pool = {type = "integer", minimum = 1, default = 5},
                },
                required = {"url"},
            },
        },
    },
}

local plugin_name = "ECourt"

local _M = {
    version  = 0.1,
    priority = 1950,
    name     = plugin_name,
    schema   = plugin_schema,
}

 


 
 

 
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

    local res, err = httpc:request_uri("https://postdev.timbleglance.com/api/address_classification/", {
        method = "POST",
        ssl_verify = false,
        headers = {
            ["app-id"] = "K&I54tg54t45@WEFG%T^y^Hr54etgYarjn",
            ["Content-Type"] = "application/json",
            ["api-key"] = "O)L(h5r4tgfb3t4grftfht%5w$45pgtoarjn",
            ["Cookie"] = "sessionid=v47rj5rqkylfg8xlmzip6yh60b770ksa; sessionid=t6wekupmmtvv59bai5fxqazl8fehu8uz"
        },
        body =  body_data
    })

    if not res then
        return 500 , err
    end

    if not res.body then
        ngx.log(ngx.ERR, "No response body received from token fetch")
        return 500, "No response body"
    end

    local ok2, decoded = pcall(cjson.decode, res.body)
    if not ok2 or not decoded then
        ngx.log(ngx.ERR, "Failed to decode token response: ", res.body)
        return 500, "JSON decode error"
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
                matrix[i - 1][j] + 1,        -- deletion
                matrix[i][j - 1] + 1,        -- insertion
                matrix[i - 1][j - 1] + cost  -- substitution
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
    local last_resp, err
    local flag = true
    local found = false
    for _, node in ipairs(conf.nodes) do
        -- assembly request parameters
        local params = {
            method = "POST",
            ssl_verify = false,
            -- keepalive = node.keepalive,
        }

        -- initialize new http connection
        local httpc = http.new()
        httpc:set_timeout(node.timeout)

        if last_resp ~= nil then            
            local decoded_body, err = core.json.decode(last_resp.body)
            if not decoded_body then
                return 500, "JSON decoding failed"
            end
             
            -- core.log.warn("decoded_body in pipeline lua", core.json.encode(decoded_body['data']['uan_number']))
            local statusCode = decoded_body and decoded_body['status'] or decoded_body['response_code'] or decoded_body['status_code']
            
            local statusCode = tonumber(statusCode) 
            if statusCode ~= 101 and  statusCode ~= 200 then
                decoded_body['status'] = statusCode
                return core.response.exit(last_resp.status,decoded_body)
             
            end
             
            if decoded_body["result"] then
                decoded_body = {
                    verify_id = decoded_body['result']['task_id'],
                }
                 
            else
                 decoded_body = {}
            end

            params.method = "POST" 
            params.body = core.json.encode(decoded_body)
        else
            -- setup header, query and body for first request (upstream)
            params.method = core.request.get_method()
            params.query = core.request.get_uri_args()
            local body, err = core.request.get_body()
              
            
            if err then
                return 503
            end
            if body then
                params.body = body
            end
        end
          
        local start_time = ngx.now()
        
        local resp_json
        while (ngx.now() - start_time) < 15 do
            last_resp, err = httpc:request_uri(node.url, {
                method = "POST",
                body = params.body,   
                headers = {
                    ["Content-Type"] = "application/json",
                    ["api-key"] = "fL7XrW8yP2jM1BnAoK9sTb6cVu3Dq5HeZgY0"
                },
                ssl_verify = false
            })
            
            if last_resp and last_resp.body then
                local ok, decoded = pcall(core.json.decode, last_resp.body)
                -- decode = core.json.decode(decoded)
                 
                if flag then
                    flag = false
                    resp_json = decoded
                    break
                
                elseif decoded and decoded.response_message == "Processing done" then
                    found = true
                    resp_json = decoded
                    break
                end
            end
            ngx.sleep(1)  -- Sleep for 1 second before next poll
        end
        
    end

    if found then
            for key, value in pairs(last_resp.headers) do
                local lower_key = string.lower(key)
                if lower_key == "transfer-encoding"
                    or lower_key == "connection" then
                    goto continue
                end
                -- set response header
                core.response.set_header(key, value)

                ::continue::
            end

            local body, err = core.request.get_body()
            body = core.json.decode(body)
            local input_address = body.address or ""

            local decoded_body, err = core.json.decode(last_resp.body)
            
            -- Check if decoding succeeded
            if not decoded_body then
                return last_resp.status, last_resp.body
            end
    
            local matching_scores = {}
            
            if decoded_body.result then

                for k, v in pairs(decoded_body.result) do
                    local result_address = v.address or ""
                    local inputAddressData,error = address_classification(input_address)
                    local resultAddressData = address_classification(result_address)
                     
                    local houseNumber = ""
                    local locality = ""
                    local area_type = ""

                    if inputAddressData.response_code == 101 then
                        houseNumber = inputAddressData.result.house_number or ""
                        locality = inputAddressData.result.landmark or ""
                        area_type = inputAddressData.result.area_type or ""
                    end
                    local resultHouseNumber = ""
                    local resultLocality = ""
                    local resultAreaType = ""
                    if resultAddressData.response_code == 101 then
                        resultHouseNumber = resultAddressData.result.house_number or ""
                        resultLocality = resultAddressData.result.landmark or ""
                        resultAreaType = resultAddressData.result.area_type or ""
                    end
                    

                    local houseScore = string_similarity(houseNumber, resultHouseNumber)
                    local localityScore = string_similarity(locality, resultLocality)
                    local areaTypeScore = string_similarity(area_type, resultAreaType)

                    if houseScore >= 90 then
                        v['house_number'] = "EXACT_MATCH"
                    elseif houseScore >= 70 and houseScore < 90 then
                        v['house_number'] = "PARTIAL_FUZZY"
                    else
                        v['house_number'] = "NO_MATCH"
                    end

                    if localityScore >= 90 then
                        v['landmark'] = "EXACT_MATCH"
                    elseif localityScore >= 70 and localityScore < 90 then
                        v['landmark'] = "PARTIAL_FUZZY"
                    else
                        v['landmark'] = "NO_MATCH"
                    end

                    if areaTypeScore >= 90 then
                        v['area_type'] = "EXACT_MATCH"
                        v['areaType'] = area_type
                    elseif areaTypeScore >= 70 and areaTypeScore < 90 then
                        v['area_type'] = "PARTIAL_FUZZY"
                        v['areaType'] = area_type
                    else      
                        v['area_type'] = "NO_MATCH"
                    end
                     
                end
            else
                core.log.warn("No result key found in decoded_body")
            end
            
            return last_resp.status, core.json.encode(decoded_body)
        else
            return last_resp.status, core.json.encode(decoded_body)
        end
    
end


return _M