local core = require("apisix.core")
local json = require("cjson.safe")
local ngx = ngx
local math = math
local os = os
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")

local plugin_name = "tb"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 900,
    name = plugin_name,
    schema = schema,
}


local function generate_request_id()
    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random .bytes(32)  -- Generate 32 random bytes
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())  -- Return SHA-256 hash as hex string
end

-- Sorted JSON
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

function _M.access(conf, ctx)
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()
    local request_body = json.decode(body_data) or {}

    local acct_no = request_body["Account_No"]
    local ifsc = request_body["ifsc"]

    if not acct_no or not ifsc then
        return 400, { message = "Missing Account_No or ifsc", status = "102" }
    end

    local new_body = {
        entityId = "2c59c369-67b2-42a7-afa5-4491a58a8e7c",
        programId = "286",
        requestId = generate_request_id(),
        custIfsc = ifsc,
        custAcctNo = acct_no,
        trackingRefNo = "tb4fq3fabav",
        txnType = "IMPS"
    }

    ngx.ctx.response_bodyRequest = request_body

    local encoded = json.encode(new_body)
    ngx.req.set_body_data(encoded)
    ngx.req.set_header("Content-Length", #encoded)
end

function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if not ngx.ctx.response_bodyCr then
        ngx.ctx.response_bodyCr = {}
    end

    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.response_bodyCr, chunk)
        ngx.arg[1] = nil
    end

    if eof then
        local full_body = table.concat(ngx.ctx.response_bodyCr)
        local data = json.decode(full_body)
        local result = {}

        if ngx.status == 401 then
            result.response_code = 401
            result.response_message = "Bad credentials provided"
        elseif ngx.status == 403 then
            result.response_code = 403
            result.response_message = "Access Denied"
        elseif ngx.status == 429 then
            result.response_code = 429
            result.response_message = "Limit exceeds, Too many requests"
        elseif data then
            result = data

            if result.response_code == 101 and result.result and type(result.result) == "table" then
                if result.result.result_json then
                    result.result.result_json = nil
                end
            end
       
            result["input"] = ngx.ctx.response_bodyRequest
        end

        -- Check for a specific key in the request headers
        ctx.var.isBulk = "API"
        local header_key = "x-trx-type" -- Replace with the desired header key
 --       core.log.warn("data bulk", new_json.encode(ngx.req.get_headers()))
        if ngx.req.get_headers()[header_key] then
            ctx.var.isBulk = ngx.req.get_headers()[header_key]
--            core.log.warn("data bulk", new_json.encode(ctx.var.isBulk))
        end

        -- Check for a specific key in the request headers
        ctx.var.isLogIn_id = 0
        local header_key_login = "x-login-id"  
        if ngx.req.get_headers()[header_key_login] then
            ctx.var.isLogIn_id = ngx.req.get_headers()[header_key_login]
        end

        local new_body = sorted_json(result)
        ngx.arg[1] = new_body
        ngx.arg[2] = true
    end
end

return _M
