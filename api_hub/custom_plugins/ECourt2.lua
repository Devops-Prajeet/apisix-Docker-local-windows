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
    priority = 1000,
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

-- Return % similarity (0-100)
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
    local input_address
    for _, node in ipairs(conf.nodes) do
        -- assembly request parameters
        local params = {
            method = "POST",
            ssl_verify = false,
            -- keepalive = node.keepalive,
        }

        -- attaching connection pool configuration
        -- if node.keepalive then
        --     params.keepalive_timeout = node.keepalive_timeout
        --     params.keepalive_pool = node.keepalive_pool
        -- end

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

            -- Setup body from last success response
            params.method = "POST" 
            params.body = core.json.encode(decoded_body)
        else
            -- setup header, query and body for first request (upstream)
            params.method = core.request.get_method()
            params.query = core.request.get_uri_args()
            local body, err = core.request.get_body()
-- address match case
            -- local input_name = body and body.name or ""
            -- local input_address = body and body.address or ""
            -- local result_name = final_body.result and final_body.result.name or ""
            -- local result_address = final_body.result and final_body.result.address or ""


            -- local name_score = string_similarity(input_name, result_name)
            -- local address_score = string_similarity(input_address, result_address)


              
            
            if err then
                return 503
            end
            if body then
                params.body = body
            end
        end
          
         
        last_resp, err = httpc:request_uri(node.url, {
            method = "POST",
            body = params.body,  -- Manually passing a static payload



            headers = {
                ["Content-Type"] = "application/json",
                ["api-key"] = "123456789"
            },
            ssl_verify = false
        })     
        if not last_resp then
            return 500, "request failed: " .. err
        end

        local body, err = core.request.get_body()
        body = core.json.decode(body)
        input_address = body.address
        -- local input_address_data = body and body.address or ""
        --  core.log.error("sanjay is pro dev", core.json.encode(body))
        -- input_address= body.input

        -- local input_address= core.json.decode(input_address_data)

        -- local input_address = body and body.address or ""
   
        -- core.log.warn("anil and kumar", core.json.encode(body))

        -- core.log.error("branch------------: ", core.json.encode(decoded_body.result))

    end

    -- send all headers from last node's response to client
    for key, value in pairs(last_resp.headers) do
        -- Avoid setting Transfer-Encoding and Connection,
        -- they can be broken for response headers.
        local lower_key = string.lower(key)
        if lower_key == "transfer-encoding"
            or lower_key == "connection" then
            goto continue
        end

        -- set response header
        core.response.set_header(key, value)

        ::continue::
    end
    -- local result_address = last_resp.result and last_resp.result.address or ""
    -- local address_score = string_similarity(input_address, result_address)

    -- last_resp["matching_scores"] = {
    -- address_match_score = address_score
    --  }



    -- local decoded_body, err = core.json.decode(last_resp.body)
    -- core.log.error("nanu------------: ", core.json.encode(decoded_body.result))
    -- if not decoded_body then
    --     core.log.error("Failed to decode last_resp.body: ", err)
    --     return last_resp.status, last_resp.body
    -- end

    -- -- Compute address similarity scores
    -- local matching_scores = {}
    -- -- core.log.error("kulll------------: ", core.json.decode(last_resp.body.result))
    -- if decoded_body.result then
    --     core.log.error("address------------: ", core.json.decode(last_resp.body.result))
    --     for k, v in pairs(decoded_body.result) do
    --         local result_address = v.address or ""
    --         local address_score = string_similarity(input_address, result_address)
    --         matching_scores[k] = {
    --             address_match_score = address_score
    --         }
    --     end
    -- end

    -- -- Attach scores to the decoded response body
    -- decoded_body["matching_scores"] = matching_scores

    -- -- Encode back to JSON and return
    -- return last_resp.status, core.json.encode(decoded_body)



    local decoded_body, err = core.json.decode(last_resp.body)

    -- Check if decoding succeeded
    if not decoded_body then
        core.log.error("Failed to decode last_resp.body: ", err)
        return last_resp.status, last_resp.body
    end

    -- Log the full result
    core.log.error("nanu------------: ", core.json.encode(decoded_body.result))

    -- Compute address similarity scores
    local matching_scores = {}

    if decoded_body.result then
        core.log.error("baguu------------: ", core.json.encode(decoded_body.result))

        for k, v in pairs(decoded_body.result) do
            local result_address = v.address or ""
             core.log.error("kkkkkli------------: ", core.json.encode(v))

             core.log.error("input_addressanilkumar------------: ", core.json.encode(input_address))
            local address_score = string_similarity(input_address, result_address)
            core.log.error("address_score------------: ", core.json.encode(address_score))
            v['address_matching_scores'] = address_score
            -- matching_scores[k] = {
            --     address_match_score = address_score
            -- }
        end

      
    else
        core.log.warn("No result key found in decoded_body")
    end

    -- Attach scores to the response
    -- decoded_body = decoded_body.result

    -- decoded_body["matching_scores"] = matching_scores
    -- decoded_body = {
    --     result = decoded_body
    -- }

    -- Return updated JSON response
    return last_resp.status, core.json.encode(decoded_body)

    end

return _M