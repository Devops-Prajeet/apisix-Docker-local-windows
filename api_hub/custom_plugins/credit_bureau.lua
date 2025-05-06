local core = require("apisix.core")
local json = require("cjson.safe")
local ngx = ngx
local math = math
local os = os

local plugin_name = "credit_bureau"

local schema = {
    type = "object",
    properties = {
        client_ref_num = { type = "string" },
        name_lookup = { type = "integer" },
        consent_message = { type = "string" },
        consent_acceptance = { type = "string" },
        device_type = { type = "string" },
        device_id = { type = "string" },
        device_ip = {
            type = "array",
            items = { type = "string" },
            default = {
                "192.168.1.10",
                "192.168.1.20",
                "192.168.1.30",
                "192.168.1.40",
                "192.168.1.50"
            }
        }
    },
    required = {
        "client_ref_num",
        "name_lookup",
        "consent_message",
        "consent_acceptance",
        "device_type",
        "device_id"
    }
}

local _M = {
    version = 0.1,
    priority = 900,
    name = plugin_name,
    schema = schema,
}

-- Generate a random 4-digit OTP
local function generate_otp()
    math.randomseed(os.time() + ngx.worker.pid())
    return tostring(math.random(1000, 9999))
end

-- Deepcopy function for tables
local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for key, value in next, orig, nil do
            copy[deepcopy(key)] = deepcopy(value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- IST timestamp in format YYYYMMDD-HH:MM:SS
local function get_ist_timestamp()
    local utc = os.time()
    local ist = utc + (5.5 * 3600)
    return os.date("%Y%m%d-%H:%M:%S", ist)
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



function _M.access(conf, ctx)
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()
    local request_body = json.decode(body_data) or {}


     -- Safely fallback to default device_ip list if missing
     local ip_list = conf.device_ip or {
        "192.168.1.10",
        "192.168.1.20",
        "192.168.1.30",
        "192.168.1.40",
        "192.168.1.50"
    }

    -- Random IP
    local selected_ip = ip_list[math.random(#ip_list)]

    -- Random OTP
    local otp = generate_otp()

    --Timestamp
    local timestamp = get_ist_timestamp()

    ngx.ctx.response_bodyRequest = deepcopy(request_body)

    -- Inject new fields
    request_body["client_ref_num"] = conf.client_ref_num
    request_body["name_lookup"] = conf.name_lookup
    request_body["consent_message"] = conf.consent_message
    request_body["consent_acceptance"] = conf.consent_acceptance
    request_body["device_type"] = conf.device_type
    request_body["device_id"] = conf.device_id
    request_body["otp"] = otp
    request_body["timestamp"] = timestamp
    request_body["device_ip"] = selected_ip

    local new_body = json.encode(request_body)
    ngx.req.set_body_data(new_body)
    ngx.req.set_header("Content-Length", #new_body)

    --core.log.info("Modified request with OTP: ", otp, ", timestamp: ", timestamp, ", IP: ", selected_ip)
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

        -- core.log.warn("DATA-----------------------------------------------------------", data)

        if ngx.status == 401 then
            result["response_code"] = 401
            result["response_message"] = "Bad credentials provided"
            -- result["result"] = {}
        elseif ngx.status == 403 then
            result["response_code"] = 403
            result["response_message"] = "Access Denied"
            -- result["result"] = {}
        elseif ngx.status == 429 then
            result["response_code"] = 429
            result["response_message"] = "Limit exceeds, Too many requests"
            -- result["result"] = {}
        elseif data then
            result = data
            if result.response_code == 101 and result.result and type(result.result) == "table" then
                if result.result.result_json ~= nil then
                    result.result.credit_bureau_report = result.result.result_json
                    result.result.result_json = nil
                end

                 
            elseif result.response_code == 103 then
                result.result = {}
            elseif result.response_code == 102 then
                data["billable"]="False"
                data["success"]="False"
                if ngx.status == 200 then
                    data["billable"]="True"
                    data["success"]="True"
                    data["response_code"]=103
                    data['response_message'] = "No records found for the given ID or combination of inputs"
                    result.result = {}
                    result.result_code = nil
                else
                    data["response_code"]=102
                    data["response_message"]="Invalid ID number or combination of inputs"
                    result.result = {}
                end

            end
            result["input"] = ngx.ctx.response_bodyRequest
        end

        -- local new_body = json.encode(result)
        local new_body = sorted_json(result)
        ngx.arg[1] = new_body
        ngx.arg[2] = true
    end
end

return _M
