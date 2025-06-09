local core = require("apisix.core")
local redis = require("resty.redis")
local cjson = require("cjson.safe")
local consumer_mod = require("apisix.consumer")
local http = require "resty.http"
local plugin_name = "cache_redis_new"

local schema = {
    type = "object",
    properties = {
        redis_host = { type = "string", default = "13.203.59.217" },
        redis_port = { type = "integer", default = 6379 }, 
        redis_key_prefix = { type = "string", default = "apisix:response:" },
        redis_ttl = { type = "integer", default = 86400 }
    }
}

local _M = {
    version = 1.0,
    priority = 1200,
    name = plugin_name,
    schema = schema
}

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
    if ngx.ctx.override_status then
        ngx.status = ngx.ctx.override_status
    end
end

local function get_config_value(value, default)
    return value ~= nil and value or default
end

local function get_consumer_by_key(api_key)
    local httpc = http.new()
    local res, err = httpc:request_uri("http://127.0.0.1:9180/apisix/admin/consumers", {
        method = "GET",
        headers = {
            ["X-API-KEY"] = "edd1c9f034335f136f87ad84b625c8f1"
        }
    })

    if not res then
        core.log.error("Failed to request consumers: ", err)
        return nil
    end

    local consumers, decode_err = core.json.decode(res.body)
    if not consumers or not consumers.list then
        core.log.error("Invalid consumer list response: ", decode_err)
        return nil
    end

    for _, consumer in ipairs(consumers.list) do
        if consumer.value and consumer.value.plugins and consumer.value.plugins["key-auth"] then
            local stored_key = consumer.value.plugins["key-auth"].key
            if stored_key == api_key then
                return consumer.value.username
            end
        end
    end
    return nil
end

-- function _M.access(conf, ctx)
--     local redis_host = get_config_value(conf.redis_host, "redis")
--     local redis_port = get_config_value(conf.redis_port, 6379)
--     local redis_key_prefix = get_config_value(conf.redis_key_prefix, "apisix:response:")

--     local redis_client = redis:new()
--     redis_client:set_timeout(1000)

--     local ok, err = redis_client:connect(redis_host, redis_port)
--     if not ok then
--         core.log.error("Failed to connect to Redis: ", err)
--         return
--     end

--     local ok_select, err_select = redis_client:select(2)
--     if not ok_select then
--         core.log.error("Redis SELECT failed: ", err_select)
--         return
--     end

--     local headers = ngx.req.get_headers()
--     ctx.var.apiKey = headers["api-key"]
--     ctx.var.consumer = get_consumer_by_key(ctx.var.apiKey)

--     local request_id = ctx.var.request_id or ngx.var.request_id or "unknown_request"
--     local key = redis_key_prefix .. request_id

--     local cached_response, redis_err = redis_client:get(key)
--     if cached_response and cached_response ~= ngx.null then
--         local decoded_response = cjson.decode(cached_response)
--         if decoded_response then
--             core.log.info("Cache hit for key: ", key)
--             ngx.header["Content-Type"] = "application/json"
--             ngx.say(decoded_response)
--             return ngx.exit(200)
--         else
--             core.log.error("Failed to decode cached response: ", cached_response)
--         end
--     else
--         core.log.info("Cache miss for key: ", key)
--         ctx.cache_redis_key = key
--     end

--     redis_client:set_keepalive(10000, 100)
-- end

function _M.access(conf, ctx)
    local redis_host = get_config_value(conf.redis_host, "redis")
    local redis_port = get_config_value(conf.redis_port, 6379)
    local redis_key_prefix = get_config_value(conf.redis_key_prefix, "apisix:response:")

    local redis_client = redis:new()
    redis_client:set_timeout(1000)

    local ok, err = redis_client:connect(redis_host, redis_port)
    if not ok then
        core.log.error("Failed to connect to Redis: ", err)
        return
    end

    local ok_select, err_select = redis_client:select(2)
    if not ok_select then
        core.log.error("Redis SELECT failed: ", err_select)
        return
    end

    local headers = ngx.req.get_headers()
    ctx.var.apiKey = headers["api-key"]
    ctx.var.consumer = get_consumer_by_key(ctx.var.apiKey)

    -- ✅ ADD THIS LINE BELOW
    ctx.var.original_route = ctx.matched_route and ctx.matched_route.value.uri or ""

    local request_id = ctx.var.request_id or ngx.var.request_id or "unknown_request"
    local key = redis_key_prefix .. request_id

    local cached_response, redis_err = redis_client:get(key)
    if cached_response and cached_response ~= ngx.null then
        local decoded_response = cjson.decode(cached_response)
        if decoded_response then
            core.log.info("Cache hit for key: ", key)
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

    redis_client:set_keepalive(10000, 100)
end

function _M.body_filter(conf, ctx)
    if not ctx.cache_redis_key then
        return
    end

    local res_body = ngx.arg[1]
    if not res_body or res_body == "" then
        return
    end

    -- local route = (ctx.matched_route and ctx.matched_route.value.uri or ""):gsub("^/", "")
    local route = (ctx.var.original_route or ""):gsub("^/", "")----- for mother API


    ctx.cache_response_body = {
        actual = ctx.var.responseBodyFromSource,
        tranform = res_body,
        api_id = route,
        apiKey = ctx.var.apiKey,
        username = ctx.var.consumer,
        isBulk = ctx.var.isBulk
    }
end

local function store_in_redis(premature, redis_host, redis_port, key, response_body, redis_ttl)
    if premature then
        return
    end

    local redis_client = redis:new()
    redis_client:set_timeout(1000)

    local ok, err = redis_client:connect(redis_host, redis_port)
    if not ok then
        core.log.error("Failed to connect to Redis in timer: ", err)
        return
    end

    local ok_select, err_select = redis_client:select(2)
    if not ok_select then
        core.log.error("Redis SELECT failed in timer: ", err_select)
        return
    end

    local transformData = cjson.decode(response_body.tranform) or {}
    local actualData = cjson.decode(response_body.actual) or {}

    transformData.result = nil
    transformData.api_id = response_body.api_id
    transformData.apiKey = response_body.apiKey
    transformData.username = response_body.username
    actualData.result = nil

    local data = {
        actualResponse = actualData,
        transformResponse = transformData,
        isBulk = response_body.isBulk
    }

    local dataForRedis = cjson.encode(data)
    local success, redis_err = redis_client:setex(key, redis_ttl, dataForRedis)
    if not success then
        core.log.warn("Failed to store response in Redis: ", redis_err)
    else
        core.log.warn("Stored response in Redis for key: ", key)
    end

    redis_client:set_keepalive(10000, 100)
end



function _M.log(conf, ctx)
    if not ctx.cache_redis_key or not ctx.cache_response_body then
        return
    end

    local redis_host = get_config_value(conf.redis_host, "13.203.59.217")
    local redis_port = get_config_value(conf.redis_port, 6379)
    local redis_ttl = get_config_value(conf.redis_ttl, 86400)

    local ok, err = ngx.timer.at(0, store_in_redis, redis_host, redis_port, ctx.cache_redis_key, ctx.cache_response_body, redis_ttl)
    if not ok then
        core.log.error("Failed to create async Redis timer: ", err)
    end
end

return _M
