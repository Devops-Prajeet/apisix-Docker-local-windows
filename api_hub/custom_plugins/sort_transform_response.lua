local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")

local plugin_name = "sort_transform_response"
local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 1999,
    name = plugin_name,
    schema = schema
}



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


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_timestamp()
    local now = os.time()
    local milliseconds = string.format("%.6f", ngx.now() % 1):sub(3)
    local timezone_offset = os.date("%z")
    return os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. milliseconds .. timezone_offset
end

function _M.access(conf, ctx)
    ngx.req.read_body()
    ngx.ctx.buffered_response = true
    ngx.ctx.request_timestamp = get_timestamp()
end

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
end

local function generate_transaction_id()
    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random.bytes(32)
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())
end

local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Invalid ID or input" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found" },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [401] = { BILLABLE = "False", MESSAGE = "Unauthorized" },
    [403] = { BILLABLE = "False", MESSAGE = "Request limit exceeded" }
    -- Add more as needed
}

local success_status_code = {1, 200, 101}
local invalid_status_code = {3, 102, 301, 401, 422}
local not_found_status_code = {2, 103, 4}

local function is_in_list(value, list)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if not ngx.ctx.response_body then
        ngx.ctx.response_body = {}
    end

    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.response_body, chunk)
        ngx.arg[1] = nil
    end

    if eof then
        local full_body = table.concat(ngx.ctx.response_body)
        ctx.var.responseBodyFromSource = full_body

        local data, err = json.decode(full_body)
        if not data then
            core.log.error("Failed to decode JSON: ", err)
            data = {}
        end

        local result = {}
        local status_code = data.status or data.result_code or ngx.status

        -- Handle specific HTTP statuses
        if ngx.status == 401 then
            result = {
                response_code = 401,
                response_message = "Bad credentials provided"
            }
        elseif ngx.status == 403 then
            result = {
                response_code = 403,
                response_message = "Access Denied"
            }
        elseif ngx.status == 429 then
            result = {
                response_code = 429,
                response_message = "Limit exceeded, Too many requests"
            }
        else
            -- Apply response mapping
            local mapped_code = 110
            if is_in_list(status_code, success_status_code) then
                mapped_code = 101
            elseif is_in_list(status_code, invalid_status_code) then
                mapped_code = 102
            elseif is_in_list(status_code, not_found_status_code) then
                mapped_code = 103
            end

            local billing = billable_dict[mapped_code] or { BILLABLE = "False", MESSAGE = "Unknown" }
            local request_body = ngx.req.get_body_data()
            local decoded_input = request_body and json.decode(request_body) or {}

            decoded_input["consent"] = nil
            decoded_input["consent_text"] = nil

            result = {
                transaction_id = generate_transaction_id(),
                input = decoded_input,
                response_code = mapped_code,
                response_message = billing.MESSAGE,
                billable = billing.BILLABLE,
                success = billing.BILLABLE == "True" and "True" or "False",
                request_timestamp = ngx.ctx.request_timestamp,
                response_timestamp = get_timestamp(),
                result = type(data.result) == "table" and data.result or (data.msg or {})
            }
        end

        ngx.arg[1] = sorted_json(result)
        ngx.arg[2] = true
    end
end

return _M
