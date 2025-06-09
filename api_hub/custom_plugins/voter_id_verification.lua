local core = require("apisix.core")
local plugin_name = "voter_id_verification"
local json = require("cjson.safe")
local ngx = ngx
local os_date = os.date

-- Minimal valid schema (empty config allowed)
local schema = {
    type = "object",
    properties = {},
    additionalProperties = false
}

local _M = {
    version = 0.1,
    priority = 2000,
    name = plugin_name,
    schema = schema
}

local function safe(val)
    if val == nil or val == ngx.null or val == "" then
        return "N/A"
    end
    return val
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end




local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },
    [2] = { BILLABLE = "True", MESSAGE = "Invalid ID Number or Combination of Inputs" },
    [3] = { BILLABLE = "False", MESSAGE = "Multiple Records Found" },
    [4] = { BILLABLE = "False", MESSAGE = "Partial Record Found" },
    [5] = { BILLABLE = "False", MESSAGE = "Duplicate Transaction" },
    [6] = { BILLABLE = "False", MESSAGE = "Number of inputs exceeded" },
    [401] = { BILLABLE = "False", MESSAGE = "Authkey missing or invalid" },
    [402] = { BILLABLE = "False", MESSAGE = "Your account does not have the required privilege to access this API" },
    [403] = { BILLABLE = "False", MESSAGE = "Request limit exceeded" },
    [301] = { BILLABLE = "False", MESSAGE = "Internal server error" }
}


local success_status_code = {1,200,101}
local invalid_missing_status_code = {401,301,102,3,4,5,6,402,403}
local no_record_found_status_code = {2,103}

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

function _M.body_filter(conf, ctx)
    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if not ctx.resp_body_chunks then
        ctx.resp_body_chunks = {}
    end

    if chunk then
        table.insert(ctx.resp_body_chunks, chunk)
        ngx.arg[1] = nil  -- suppress output until final chunk
    end

    if not eof then
        return
    end

    local whole_body = table.concat(ctx.resp_body_chunks)
    local data = json.decode(whole_body)
    if not data or not data.result then
        ngx.arg[1] = whole_body -- fallback to original response
        return
    end

    local r = data.result or {}
    local address = r.address or {}
    local booth = r.polling_booth or {}

    local transformed = {
        EPIC_Voter_ID_Number = safe(r.epic_number),
        Name_of_the_card_holder = safe(r.user_name_english),
        Name_of_relative = safe(r.relative_name_english),
        Relative_type = safe(r.relative_relation),
        Card_holders_gender = safe(r.user_gender),
        Card_holders_email_id = "N/A",
        Card_holder_mobile_number = "N/A",
        Card_holders_age = safe(r.user_age),
        Card_holders_date_of_birth = "N/A",
        Card_holders_house_number = "N/A",
        Name_of_the_part_Location_in_the_constituency_applicable_to_the_card_holder = "N/A",
        Parliamentary_Constituency_applicable_to_the_card_holder = safe(r.parliamentary_constituency_name),
        Parliamentary_Constituency_Number = safe(r.parliamentary_constituency_number),
        Constituency_applicable_to_the_card_holder = safe(r.constituency_part_name),
        Constituency_Number = safe(r.constituency_part_number),
        Assembly_Constituency_applicable_to_the_card_holder = safe(r.assembly_constituency_name),
        Assembly_Constituency_Number = safe(r.assembly_constituency_number),
        District_of_the_Electoral_Office = safe(address.district_name),
        District_code = safe(address.district_code),
        State_of_the_registered_Electoral_Office = safe(address.state),
        State_Code = safe(address.state_code),
        Number_of_the_part_location_in_the_constituency_applicable_to_the_card_holder = "",
        Lat_Long_for_the_polling_booth_applicable_to_the_card_holder = "N/A",
        Lat_Long_0_coordinate = "",
        Lat_Long_1_coordinate = "",
        Polling_Booth_Address_applicable_for_the_card_holder = safe(booth.name),
        Polling_Booth_Address_Number_applicable_for_the_card_holder = safe(booth.number),
        Section_of_the_constituency_part_applicable_to_the_card_holder = safe(r.constituency_section_number),
        Serial_number_of_the_card_holder_in_the_polling_list_in_the_applicable_part = safe(r.serial_number_applicable_part),
        Unique_ID_of_the_card_holder = "",
        Last_date_of_update_to_the_records_against_the_given_epic_no_in_Government_Records = safe(r.voter_last_updated_date),
        Voter_Application_Status = "N/A",
        date_time = os_date("%Y-%m-%d %H:%M:%S")
    }

    local full_response = json.decode(whole_body)

    if not full_response or type(full_response) ~= "table" then
        ngx.arg[1] = whole_body -- fallback to original response
        return
    end

    full_response.result = transformed
        ngx.arg[1] = sorted_json(full_response)
        ngx.arg[2] = true

    
end

return _M
