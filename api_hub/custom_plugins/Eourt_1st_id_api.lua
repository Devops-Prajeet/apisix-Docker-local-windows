local core = require("apisix.core")
local cjson = require("cjson.safe")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "Eourt_1st_id_api"

local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 2000,
    name = plugin_name,
    schema = schema,
}

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

local function is_in_list(value, list)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Missing name or father_name" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [422] = { BILLABLE = "False", MESSAGE = "Parameter Missing" },
    [125] = { BILLABLE = "False", MESSAGE = "Missing name or father_name" },
}

local invalid_missing_crime = {125}

local key_order = {
    "transaction_id", "input", "success", "billable", "response_code",
    "response_message", "result", "request_timestamp", "response_timestamp"
}

local function sorted_json(tbl, key_order)
    local function encode_value(v)
        if type(v) == "table" then return sorted_json(v) end
        if type(v) == "string" then return '"' .. v:gsub('"', '\\"') .. '"' end
        return tostring(v)
    end
    local items, order_lookup = {}, {}
    for _, k in ipairs(key_order or {}) do order_lookup[k] = true end
    for _, k in ipairs(key_order or {}) do
        if tbl[k] ~= nil then table.insert(items, '"' .. k .. '":' .. encode_value(tbl[k])) end
    end
    local extra_keys = {}
    for k in pairs(tbl) do
        if not order_lookup[k] then table.insert(extra_keys, k) end
    end
    table.sort(extra_keys)
    for _, k in ipairs(extra_keys) do
        table.insert(items, '"' .. k .. '":' .. encode_value(tbl[k]))
    end
    return '{' .. table.concat(items, ',') .. '}'
end

local function body_looks_like_json(body)
    local trimmed = body:match("^%s*(.-)%s*$")
    return trimmed and (trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[")
end

function _M.access(conf, ctx)
       ngx.req.set_header("Accept-Encoding", "identity")
    ngx.ctx.request_timestamp = get_timestamp()
end

function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if not ngx.ctx.resBodies then ngx.ctx.resBodies = {} end
    if chunk and chunk ~= "" then
        table.insert(ngx.ctx.resBodies, chunk)
        ngx.arg[1] = nil
    end

    if not eof then return end

    local full_body = table.concat(ngx.ctx.resBodies)
    --  core.log.warn("ANil kumarkkkkkkinside ------------------",full_body.status)

    local headers = ngx.resp.get_headers()
    local content_type = headers["Content-Type"] or headers["content-type"] or ""
    local is_json = content_type:find("application/json") or content_type:find("text/json")

    local new_json = json.new()
    new_json.encode_sparse_array(true, 1, 1)

    -- local data, err
    data, err = new_json.decode(full_body)
    if is_json and body_looks_like_json(full_body) then
        data, err = new_json.decode(full_body)
        if not data then
            core.log.error("JSON decode failed: ", err, " | Body start: ", full_body:sub(1, 100))
        end
    else
        core.log.warn("Non-JSON or invalid body. Content-Type: ", content_type, " | Head: ", full_body:sub(1, 100))
    end

    local transformed_response = nil


    if data then
        -- optional override for 401
        if ngx.status == 401 then
            -- ngx.status = 200
            core.log.warn("Status overridden from 401 to 200")
        end

        local result = {}
        local request_body = ngx.req.get_body_data()
        local ok, input_data = pcall(cjson.decode, request_body or "")
        input_data = ok and input_data or {}




        -- Remove unnecessary fields
        input_data["consent_text"] = nil
        input_data["user"] = nil
        input_data["algo_type"] = nil
        input_data["auth_token"] = nil
        input_data["scoring"] = nil
        input_data["source"] = nil

        result["input"] = input_data

        local verify_id_str = tostring(data.verify_id or "")
        result["transaction_id"] = verify_id_str:match("^%s*(.-)%s*$") ~= "" and verify_id_str or generate_transaction_id()

        local http_status = tonumber(data.status or data.result_code or full_body['status'] or 0)
 
        if data.status == 102 then
            result["response_code"] = 102
        elseif data.status == 125 then
            result["response_code"] = 125
        elseif is_in_list(http_status, invalid_missing_crime) then
            result["response_code"] = 125
        elseif is_in_list(http_status, {1, 200, 101}) then
            result["response_code"] = 101
        elseif is_in_list(http_status, {400, 5, 0, 422}) then
            result["response_code"] = 102
        elseif is_in_list(http_status, {103}) then
            result["response_code"] = 103
        else
            result["response_code"] = 110
        end

        local billable_info = billable_dict[result.response_code] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }
        result["billable"] = billable_info.BILLABLE
        result["success"] = billable_info.BILLABLE == "True" and "True" or "False"
        result["response_message"] = billable_info.MESSAGE
        result["request_timestamp"] = ngx.ctx.request_timestamp
        result["response_timestamp"] = get_timestamp()
        result["result"] = { task_id = data.verify_id }
       if result["response_code"]==125 then
           result["response_code"] = 102
           result["response_message"] = "Missing name or address"
       end

         
      

        transformed_response = sorted_json(result, key_order)
        ngx.arg[1] = transformed_response
    else
        ngx.arg[1] = full_body
    end

    ngx.ctx.transformData = {
        body = transformed_response or full_body,
        is_json = data ~= nil
    }

    ngx.arg[2] = true
end

return _M
