local core = require("apisix.core")
local redis = require("resty.redis")
local cjson = require("cjson.safe")
local consumer_mod = require("apisix.consumer")
local http = require "resty.http"
local plugin_name = "cache_redis"

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
    core.log.warn(">>> Looking up consumer for API key: ", api_key)
    local httpc = http.new()
    local res, err = httpc:request_uri("http://127.0.0.1:9180/apisix/admin/consumers", {
        method = "GET",
        headers = {
            ["X-API-KEY"] = "edd1c9f034335f136f87ad84b625c8f1"
        }
    })

    if not res then
        core.log.error("Failed to fetch consumers: ", err)
        return nil
    end

    local consumers, decode_err = core.json.decode(res.body)
    if not consumers or not consumers.list then
        core.log.warn("Consumer list decode failed: ", decode_err)
        return nil
    end

    for _, consumer in ipairs(consumers.list) do
        if consumer.value and consumer.value.plugins and consumer.value.plugins["key-auth"] then
            local stored_key = consumer.value.plugins["key-auth"].key
            if stored_key == api_key then
                core.log.warn(">>> Found consumer: ", consumer.value.username)
                return consumer.value.username
            end
        end
    end

    core.log.warn(">>> No matching consumer found.")
    return nil
end

function _M.access(conf, ctx)
    core.log.warn(">>> cache_redis ACCESS phase triggered")

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

    redis_client:select(2)

    local headers = ngx.req.get_headers()
    ctx.var.apiKey = headers["api-key"]
    core.log.warn("Received API key: ", ctx.var.apiKey)

    ctx.var.consumer = get_consumer_by_key(ctx.var.apiKey)

    local request_id = ctx.var.request_id or ngx.var.request_id or "unknown_request"
    local key = redis_key_prefix .. request_id
    ctx.cache_redis_key = key

    core.log.warn("Generated Redis key: ", key)

    local cached_response, redis_err = redis_client:get(key)
    if cached_response and cached_response ~= ngx.null then
        local decoded_response = cjson.decode(cached_response)
        if decoded_response then
            core.log.warn(">>> Redis CACHE HIT for key: ", key)
            ngx.header["Content-Type"] = "application/json"
            ngx.say(decoded_response)
            return ngx.exit(200)
        else
            core.log.error("Failed to decode cached response: ", cached_response)
        end
    else
        core.log.warn(">>> Redis CACHE MISS for key: ", key)
    end

    redis_client:set_keepalive(10000, 100)
end

function _M.body_filter(conf, ctx)
    core.log.warn(">>> cache_redis BODY_FILTER phase triggered")

    local route = ctx.matched_route and ctx.matched_route.value and ctx.matched_route.value.uri or "unknown_route"
    route = route:gsub("^/", "")

    local res_body = ngx.arg[1]
    if not ctx.cache_redis_key then
        core.log.warn("No Redis key found in ctx. Skipping body capture.")
        return
    end

    if not res_body or res_body == "" then
        core.log.warn("Empty response chunk. Skipping.")
        return
    end

    local raw_body = ctx.var.responseBodyFromSource or ""
    ctx.cache_response_body = {
        actual = raw_body,
        tranform = res_body,
        api_id = route,
        apiKey = ctx.var.apiKey,
        username = ctx.var.consumer,
        isBulk = ctx.var.isBulk,
        login_id = ctx.var.isLogIn_id
    }

    core.log.warn(">>> Captured body for caching for route: ", route)
end

local function store_in_redis(premature, redis_host, redis_port, key, response_body, redis_ttl)
    if premature then
        core.log.warn(">>> Redis store timer aborted prematurely")
        return
    end

    core.log.warn(">>> store_in_redis() called for key: ", key)

    local redis_client = redis:new()
    redis_client:set_timeout(1000)

    local ok, err = redis_client:connect(redis_host, redis_port)
    if not ok then
        core.log.error("Failed to connect to Redis in timer: ", err)
        return
    end

    redis_client:select(2)

    local transformData = cjson.decode(response_body.tranform) or {}
    local actualData = cjson.decode(response_body.actual) or {}

    transformData["result"] = nil
    transformData["api_id"] = response_body.api_id
    transformData["apiKey"] = response_body.apiKey
    transformData["username"] = response_body.username
    actualData["result"] = nil

    local data = {
        actualResponse = actualData,
        transformResponse = transformData,
        isBulk = response_body.isBulk,
        login_id = response_body.login_id
    }

    local dataForRedis = cjson.encode(data)
    core.log.warn(">>> Final data to store in Redis: ", dataForRedis)

    local success, redis_err = redis_client:setex(key, redis_ttl, dataForRedis)
    if not success then
        core.log.warn("Failed to store response in Redis: ", redis_err)
    else
        core.log.warn(">>> Successfully stored response in Redis for key: ", key)
    end

    redis_client:set_keepalive(10000, 100)
end

function _M.log(conf, ctx)
    core.log.warn(">>> cache_redis LOG phase triggered")

    if not ctx.cache_redis_key or not ctx.cache_response_body then
        core.log.warn("Missing data in log phase: cache_redis_key=", ctx.cache_redis_key, ", response_body=", ctx.cache_response_body and "yes" or "nil")
        return
    end

    local redis_host = get_config_value(conf.redis_host, "redis")
    local redis_port = get_config_value(conf.redis_port, 6379)
    local redis_ttl = get_config_value(conf.redis_ttl, 86400)

    local ok, err = ngx.timer.at(0, store_in_redis, redis_host, redis_port, ctx.cache_redis_key, ctx.cache_response_body, redis_ttl)
    if not ok then
        core.log.error("Failed to create async Redis timer: ", err)
    else
        core.log.warn(">>> Async Redis write timer started for key: ", ctx.cache_redis_key)
    end
end

return _M
