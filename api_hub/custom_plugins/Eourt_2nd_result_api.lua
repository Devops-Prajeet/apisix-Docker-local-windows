local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "Eourt_2nd_result_api"

local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 2000,
    name = plugin_name,
    schema = schema,
}

local function is_in_list(value, list)
    if type(list) ~= "table" then
        return false
    end

    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_timestamp()
    local now = os.time()
    local micro = string.format("%.6f", ngx.now() % 1):sub(3)
    local tz = os.date("%z")
    return os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. micro .. tz
end

local function generate_transaction_id()
    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random.bytes(32)
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())
end

-- 🧼 Enhanced Sanitization for Backslashes & Invalid UTF-8


local function sanitize_string(value)
    if type(value) ~= "string" then
        return value
    end

    -- Remove control characters
    value = value:gsub("[%z\1-\31\127]", "")

    -- Normalize backslashes
    value = value:gsub("\\", "\\\\") -- double all backslashes

    -- Escape quotes (to prevent breaking JSON)
    value = value:gsub('"', '\\"')

    return value
end

local function deep_sanitize(tbl)
    if type(tbl) ~= "table" then return tbl end
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            tbl[k] = sanitize_string(v)
        elseif type(v) == "table" then
            tbl[k] = deep_sanitize(v)
        end
    end
    return tbl
end

local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "True", MESSAGE = "Missing 'name' or 'father_name" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [400] = { code = 102, billable = false, message = "Parameter Missing" },
    [401] = { code = 401, billable = false, message = "Bad credentials provided" },
    [402] = { code = 110, billable = false, message = "Source Unavailable" },
    [403] = { code = 110, billable = false, message = "Source Unavailable" },
    [404] = { code = 110, billable = false, message = "Source Unavailable" },
    [422] = { BILLABLE = "False", MESSAGE = "Parameter Missing" },
    [302] = { code = 110, billable = false, message = "Source Unavailable" },
    [500] = { code = 110, billable = false, message = "Source Unavailable" },
    [502] = { code = 110, billable = false, message = "Source Unavailable" },
    [503] = { code = 110, billable = false, message = "Source Unavailable" },
    [504] = { code = 110, billable = false, message = "Source Unavailable" },
}

local success_status_code = {1, 200, 101, 0}
local invalid_missing_status_code = {400, 5, 422, 102}
local no_record_found_status_code = {103}

function _M.access(conf, ctx)
    ngx.req.set_header("Accept-Encoding", "identity")
    ngx.ctx.request_timestamp = get_timestamp()

    local req_body, err = core.request.get_body()
    if not req_body then
        return 400, { message = "Invalid request body", status = 102 }
    end

    local data, err = json.decode(req_body)
    if not data then
        return 400, { message = "Invalid JSON format", status = 102 }
    end

    if data.task_id ~= nil then
        data.verify_id = data.task_id
        data.task_id = nil
        ngx.req.set_body_data(json.encode(data))
    else
        return 200, { message = "task_id not found", status = 102 }
    end
end

local function sorted_json(tbl, key_order)
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

    local items = {}
    if key_order then
        for _, k in ipairs(key_order) do
            if tbl[k] ~= nil then
                table.insert(items, '"' .. k .. '":' .. encode_value(tbl[k]))
            end
        end
    end

    local remaining_keys = {}
    local order_lookup = {}
    for _, k in ipairs(key_order or {}) do
        order_lookup[k] = true
    end

    for k in pairs(tbl) do
        if not order_lookup[k] then
            table.insert(remaining_keys, k)
        end
    end

    table.sort(remaining_keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(remaining_keys) do
        table.insert(items, '"' .. tostring(k) .. '":' .. encode_value(tbl[k]))
    end

    return '{' .. table.concat(items, ',') .. '}'
end

local key_order = {
    "transaction_id", "input", "success", "billable",
    "response_code", "response_message", "result",
    "request_timestamp", "response_timestamp"
}

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

        local new_json = json.new()
        new_json.encode_sparse_array(true, 1, 1)

        local data, err = new_json.decode(full_body)

        local result = {}
        if ngx.status == 401 then
            result["response_code"] = 401
            result["response_message"] = "Bad credentials provided"
            ngx.arg[1] = new_json.encode(result)
            ngx.arg[2] = true
            return
        elseif ngx.status == 403 then
            result["response_code"] = 403
            result["response_message"] = "Access Denied"
            ngx.arg[1] = new_json.encode(result)
            ngx.arg[2] = true
            return
        elseif ngx.status == 422 then
            result["response_code"] = 422
            result["response_message"] = "Parameter Missing"
            ngx.arg[1] = new_json.encode(result)
            ngx.arg[2] = true
            return
        elseif ngx.status == 429 then
            result["response_code"] = 429
            result["response_message"] = "Limit exceeds , Too many requests"
            ngx.arg[1] = new_json.encode(result)
            ngx.arg[2] = true
            return
        end

        local request_body = ngx.req.get_body_data()
        local input_data = request_body and pcall(json.decode, request_body) and json.decode(request_body) or {}

        if input_data["verify_id"] then
            input_data["task_id"] = input_data["verify_id"]
            input_data["verify_id"] = nil
        end

        result["input"] = input_data
        result["transaction_id"] = generate_transaction_id()

        local statusCode = data and data.status or data.result_code
        local http_status = tonumber(statusCode)

        if data and data.status == 102 then
            result["response_code"] = 102
            result["billable"] = "False"
            result["success"] = "False"
        elseif is_in_list(http_status, success_status_code) then
            result["response_code"] = 101
        elseif is_in_list(http_status, invalid_missing_status_code) then
            result["response_code"] = 102
        elseif is_in_list(http_status, no_record_found_status_code) then
            result["response_code"] = 103
        else
            result["response_code"] = 110
        end

        local billable_info = billable_dict[result["response_code"]] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }

        result["billable"] = billable_info.BILLABLE
        result["success"] = billable_info.BILLABLE == "True" and "True" or "False"
        if not result["response_message"] then
            result["response_message"] = billable_info.MESSAGE
        end

        result["request_timestamp"] = ngx.ctx.request_timestamp
        result["response_timestamp"] = get_timestamp()

        if data and data.message then
            local msg_data = tostring(data.message):match("^%s*(.-)%s*$")
            if msg_data == "verify_id not found" then
                result["response_message"] = "task_id not found"
                result["result"] = {}
                result["billable"] = "False"
                result["success"] = "False"
            elseif msg_data == "Invalid request body" or msg_data == "task_id not found" then
                result["result"] = {}
                result["billable"] = "False"
                result["success"] = "False"
                result["response_message"] = "task_id parameter missing"
            else
                result["response_message"] = msg_data
                result["result"] = {}
            end
        end

        if data and data.cases then
            result["result"] = data.cases or {}
        end

        ctx.var.isBulk = ngx.req.get_headers()["x-trx-type"] or "API"
        ctx.var.isLogIn_id = ngx.req.get_headers()["x-login-id"] or 0

        -- 🧼 Final sanitization before encoding to JSON
        deep_sanitize(result)

        ngx.arg[1] = sorted_json(result, key_order)
        ngx.arg[2] = true
    end
end

return _M
