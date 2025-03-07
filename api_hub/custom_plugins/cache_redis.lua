local core = require("apisix.core")
local redis = require("resty.redis")
local cjson = require("cjson.safe")  -- JSON encoding/decoding
local consumer_mod = require("apisix.consumer")
local http = require "resty.http"
local plugin_name = "cache_redis"

local schema = {
    type = "object",
    properties = {
        redis_host = { type = "string", default = "13.203.59.217" },
        redis_port = { type = "integer", default = 6378 },
        redis_key_prefix = { type = "string", default = "apisix:response:" },
        redis_ttl = { type = "integer", default = 86400 } -- Cache TTL (24 hours)
    }
}

local _M = {
    version = 1.0,
    priority = 1200,  -- Ensures this plugin runs before others
    name = plugin_name,
    schema = schema
}

-- ✅ Helper function to ensure default values
local function get_config_value(value, default)
    return value ~= nil and value or default
end

local function get_consumer_by_key(api_key)
    local httpc = http.new()
    local res, err = httpc:request_uri("http://49.205.172.103:9180/apisix/admin/consumers", {
        method = "GET",
        headers = {
            ["X-API-KEY"] = "edd1c9f034335f136f87ad84b625c8f1"
        }
    })

    local consumers, decode_err = core.json.decode(res.body)

    -- if consumers then
    --     core.log.warn("Failed to decode JSON response: ", core.json.encode(consumers['list']))
    --     -- return nil
    -- end

    
    -- core.log.warn("Unexpected response format from APISIX Admin API",type(res.body))
    -- if type(consumers) ~= "table" or not consumers.list then
    --     core.log.warn("Unexpected response format from APISIX Admin API")
       
    -- end
    for _, consumer in ipairs(consumers['list']) do
        if consumer.value and consumer.value.plugins and consumer.value.plugins["key-auth"] then
            local stored_key = consumer.value.plugins["key-auth"].key
            if stored_key == api_key then
                return consumer.value.username -- Return the matching username
            end
        end
    end

    return nil
end

-- 🔹 Access Phase: Check Redis Cache Before Forwarding Request
function _M.access(conf, ctx)
    -- ✅ Ensure default values are set
    local redis_host = get_config_value(conf.redis_host, "13.203.59.217")
    local redis_port = get_config_value(conf.redis_port, 6378)
    local redis_key_prefix = get_config_value(conf.redis_key_prefix, "apisix:response:")

    local redis_client = redis:new()
    redis_client:set_timeout(1000) -- 1 sec timeout

    -- Connect to Redis
    local ok, err = redis_client:connect(redis_host, redis_port)
    if not ok then
        core.log.error("Failed to connect to Redis: ", err)
        return
    end
    
    local headers = ngx.req.get_headers()
    ctx.var.apiKey = headers['api-key']

    local consumer = get_consumer_by_key(ctx.var.apiKey)
    ctx.var.consumer  = consumer
    -- Ensure `ctx.var.request_id` is available
    local request_id = ctx.var.request_id or ngx.var.request_id or "unknown_request"
    local key = redis_key_prefix .. request_id

    -- Try to get cached response
    local cached_response, redis_err = redis_client:get(key)
    if cached_response and cached_response ~= ngx.null then
        -- Deserialize JSON response
        local decoded_response = cjson.decode(cached_response)
        if decoded_response then
            core.log.info("Cache hit for key: ", key)

            -- Serve cached body
            ngx.header["Content-Type"] = "application/json"
            ngx.say(decoded_response)
            return ngx.exit(200)
        else
            core.log.error("Failed to decode cached response: ", cached_response)
        end
    else
        core.log.info("Cache miss for key: ", key)
        ctx.cache_redis_key = key
    end

    -- Close Redis connection
    redis_client:set_keepalive(10000, 100)
end

-- 🔹 Body Filter Phase: Capture Response (Cannot Write to Redis Here!)
function _M.body_filter(conf, ctx)
    local route = ctx.matched_route.value.uri
    route = route:gsub("^/", "")
    if not ctx.cache_redis_key then
        return -- No key means response was already served from cache
    end

    local res_body = ngx.arg[1] -- Get response body
     
    if not res_body or res_body == "" then
        return -- Don't cache empty responses
    end

    -- ✅ Store response in context (for async Redis write)
    ctx.cache_response_body = {
        actual = ctx.var.responseBodyFromSource,
        tranform = res_body,
        api_id = route,
        apiKey = ctx.var.apiKey,
        username = ctx.var.consumer
    }
    
    
end

-- 🔹 Timer (Background Task) to Write to Redis
local function store_in_redis(premature, redis_host, redis_port, key, response_body, redis_ttl)  
    -- local vardata = ctx.var.upstream_response_body
    -- core.log.warn("Stored response in Redis for klocal actual_body = ctx.var.upstream_response_bodyey: ", vardata )
    if premature then
        return
    end

    local redis_client = redis:new()
    redis_client:set_timeout(1000) -- 1 sec timeout

    -- Connect to Redis
    local ok, err = redis_client:connect(redis_host, redis_port)
    if not ok then
        core.log.error("Failed to connect to Redis in timer: ", err)
        return
    end
     
     
    -- core.log.warn("Stored response in Redis for klocal actual_body = ctx.var.upstream_response_bodyey: ", response_body.actual )
    local actualResponse = response_body.actual
    local transformResponse = response_body.tranform

    local transformData, errs = cjson.decode(transformResponse)
    local actualData, errs = cjson.decode(actualResponse)

    transformData['result'] = nil
    transformData['api_id'] = response_body.api_id
    transformData['apiKey'] = response_body.apiKey
    transformData['username'] = response_body.username
    actualData['result'] = nil


    local data = {
        actualResponse = actualData,
        transformResponse = transformData
    }  

    -- Store response in Redis with TTL
    local dataForRedis = cjson.encode(data)
    local success, redis_err = redis_client:setex(key, redis_ttl, dataForRedis)
    if not success then
        core.log.error("Failed to store response in Redis: ", redis_err)
    else
        core.log.info("Stored response in Redis for key: ", key)
    end

    -- Close Redis connection
    redis_client:set_keepalive(10000, 100)
end

-- 🔹 Log Phase: Trigger Async Redis Write
function _M.log(conf, ctx)
    if not ctx.cache_redis_key or not ctx.cache_response_body then
        return -- No response captured
    end

    -- ✅ Ensure default values are set
    local redis_host = get_config_value(conf.redis_host, "13.203.59.217")
    local redis_port = get_config_value(conf.redis_port, 6378)
    local redis_ttl = get_config_value(conf.redis_ttl, 86400) -- Default 10 min TTL

    -- ✅ Use a timer to perform Redis write asynchronously
    local ok, err = ngx.timer.at(0, store_in_redis, redis_host, redis_port, ctx.cache_redis_key, ctx.cache_response_body, redis_ttl)
    if not ok then
        core.log.error("Failed to create async Redis timer: ", err)
    end
end

return _M
