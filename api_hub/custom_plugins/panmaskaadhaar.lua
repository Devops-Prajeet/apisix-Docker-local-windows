local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "panmaskaadhaar_enc"

local _M = {
    version = 0.1,
    priority = 2000,
    name = plugin_name,
}

_M.schema = {
    type = "object",
    properties = {
        required_key_1 = { type = "string", minLength = 1 },
        required_key_2 = { type = "string", minLength = 1 },
    },
    required = {},
}

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
end

local function get_timestamp()
    local now = os.time()
    local micro = string.format("%.6f", ngx.now() % 1):sub(3)
    local tz = os.date("%z")
    return os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. micro .. tz
end

function is_blank(value)
    return value == nil or value:match("^%s*$")
end

local function is_valid_data(data)
    if type(data) ~= "string" then return false end
    if data:match("^%s*$") then return true end
    return data:match("^[xX][xX][xX][xX][xX][xX][xX][xX]%d%d%d%d$") ~= nil
end

local function is_in_list(value, list)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

function _M.access(conf, ctx)
    ngx.ctx.request_timestamp = get_timestamp()
end

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

local function generate_transaction_id()
    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random.bytes(32)
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())
end

local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },
    [2] = { code = 103, billable = "True", message = "Invalid ID number or combination of inputs" },
    [3] = { code = 103, billable = "True", message = "Invalid ID number or combination of inputs" },
    [4] = { code = 103, billable = "True", message = "Invalid ID number or combination of inputs" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Invalid ID number or combination of inputs" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [400] = { code = 110, billable = false, message = "Source Unavailable" },
    [401] = { code = 401, billable = false, message = "Bad credentials provided" },
    [402] = { code = 110, billable = false, message = "Source Unavailable" },
    [403] = { code = 110, billable = false, message = "Source Unavailable" },
    [404] = { code = 110, billable = false, message = "Source Unavailable" },
    [301] = { code = 110, billable = false, message = "Source Unavailable" },
    [302] = { code = 110, billable = false, message = "Source Unavailable" },
    [500] = { code = 110, billable = false, message = "Source Unavailable" },
    [502] = { code = 110, billable = false, message = "Source Unavailable" },
    [503] = { code = 110, billable = false, message = "Source Unavailable" },
    [504] = { code = 110, billable = false, message = "Source Unavailable" },
}

local success_status_code = {1, 200, 101}
local invalid_missing_status_code = {102, 422}
local source_down_status = {401, 7, 402, 403, 301, 302}
local no_record_found_status_code = {2, 3, 4}

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

        local data = json.decode(full_body)



        core.log.warn("Anil kumar------------",full_body)
        local request_body = ngx.req.get_body_data()
        local input_data = json.decode(request_body or "{}") or {}

        input_data["consent"] = nil
        input_data["consent_text"] = nil

        local result_data = {
            transaction_id = generate_transaction_id(),
            input = input_data,
            request_timestamp = ngx.ctx.request_timestamp,
            response_timestamp = get_timestamp(),
        }

        local statusCode = data and data.status or data.result_code
        local http_status = tonumber(statusCode)

        if is_in_list(http_status, success_status_code) then
            result_data.response_code = 101
        elseif is_in_list(http_status, invalid_missing_status_code) then
            result_data.response_code = 102
        elseif is_in_list(http_status, no_record_found_status_code) then
            result_data.response_code = 103
        elseif is_in_list(http_status, source_down_status) then
            result_data.response_code = 110
        else
            result_data.response_code = 110
        end

        local billable_info = billable_dict[result_data.response_code] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }

        result_data.billable = billable_info.BILLABLE
        result_data.success = billable_info.BILLABLE == "True" and "True" or "False"
        result_data.response_message = billable_info.MESSAGE

        local masked_aadhaar = data.result and data.result.aadhaar_number or ""
        local last_four_digits = input_data.aadhaar
        local result = { masked_aadhaar = "", pan_adhr_link_status = "ERROR" }

        if result_data.response_code == 101 then
            
            if is_valid_data(masked_aadhaar) then
                local last_four_from_masked = masked_aadhaar:sub(-4)
                result.masked_aadhaar = masked_aadhaar
                result.pan_adhr_link_status = (last_four_from_masked == last_four_digits) and "YES" or "NO"
            else
                result_data.success = "False"
                result_data.billable = "False"
                result.masked_aadhaar = ""
                result_data.response_message = "Source Unavailable"  
                result_data.response_code = 110
                result.pan_adhr_link_status = "ERROR"
            end

        elseif result_data.response_code == 103 then

            result_data.success = "True"
            result_data.billable = "True"
            result.masked_aadhaar = ""
            if type(data.message) == "string"
               and data.message:find("Invalid PAN", 1, true)
                then
                    result.response_message = "No records found for the given ID or combination of inputs"
                    result.pan_adhr_link_status = "NULL"
                else
                    result.response_message = "No records found for the given ID or combination of inputs"
                    result.pan_adhr_link_status = "NOT SEEDED"
                    result.response_code = 101
            end

        elseif result_data.response_code == 102 then



            result_data.response_message = "Invalid ID number or combination of inputs"
            result_data.success = "True"
            result_data.billable = "True"
            result.masked_aadhaar = ""
            result.pan_adhr_link_status = "INVALID PAN"

        elseif result_data.response_code == 110 then
            result_data.response_message = "Source Unavailable"
            result_data.success = "False"
            result_data.billable = "False"
            result.masked_aadhaar = ""
            result.pan_adhr_link_status = "ERROR"
        end

        result_data.result = result

        ctx.var.isBulk = "API"
        local header_key = "x-trx-type" -- Replace with the desired header key
 --       core.log.warn("data bulk", new_json.encode(ngx.req.get_headers()))
        if ngx.req.get_headers()[header_key] then
            ctx.var.isBulk = ngx.req.get_headers()[header_key]
--            core.log.warn("data bulk", new_json.encode(ctx.var.isBulk))
        end


        ngx.arg[1] = sorted_json(result_data)
        ngx.arg[2] = true
    end
end

return _M
