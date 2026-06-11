local core = require("apisix.core")
local json = require("cjson.safe")
local resty_random = require("resty.random")
local str = require("resty.string")
local resty_sha256 = require("resty.sha256")
local ngx = ngx

local plugin_name = "msme"

local schema = { type = "object", properties = {} }

local _M = {
    version = 1.0,
    priority = 2000,
    name = plugin_name,
    schema = schema
}

function _M.check_schema(conf)
     return core.schema.check(schema, conf)
 end








local function get_timestamp()
    local now = os.time()
    local milliseconds = string.format("%.6f", ngx.now() % 1):sub(3)
    local timezone_offset = os.date("%z")
    return os.date("%Y-%m-%d %H:%M:%S", now) .. "." .. milliseconds .. timezone_offset
end

local function generate_transaction_id()
    local sha256 = resty_sha256:new()
    local rand_bytes = resty_random.bytes(32)
    sha256:update(rand_bytes)
    return str.to_hex(sha256:final())
end

local function encode_in_order_recursive(tbl, order_map)
    local json_safe = require("cjson.safe")

    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            return string.format("%q", tbl)
        elseif type(tbl) == "boolean" or type(tbl) == "number" then
            return tostring(tbl)
        elseif tbl == nil then
            return "null"
        else
            return json_safe.encode(tbl)
        end
    end

    -- Detect array
    local is_array = true
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" then
            is_array = false
            break
        end
    end

    if is_array then
        local arr_parts = {}
        for _, item in ipairs(tbl) do
            table.insert(arr_parts, encode_in_order_recursive(item, order_map))
        end
        return "[" .. table.concat(arr_parts, ",") .. "]"
    end

    local parts = {}
    local key_order = order_map["__self"] or {}

    for _, key in ipairs(key_order) do
        local value = tbl[key]
        local encoded = encode_in_order_recursive(value, order_map[key] or {})
        table.insert(parts, string.format("%q:%s", key, encoded))
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

function _M.header_filter(conf, ctx)
    ngx.header.content_length = nil
    ctx.var.responseFromHeader = ngx.resp.get_headers()["x-signzy-trace-id"]
end

function _M.access(conf, ctx)
    ngx.req.set_header("Accept-Encoding", "identity")
    ngx.req.read_body()
    ngx.ctx.buffered_response = true
    ngx.ctx.request_timestamp = get_timestamp()
end

local billable_dict = {
    [1] = { BILLABLE = "True", MESSAGE = "Success" },
    [2] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [3] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [7] = { BILLABLE = "False", MESSAGE = "Number of PANs exceeds the limit (5)" },
    [8] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [11] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [12] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [13] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [16] = { BILLABLE = "False", MESSAGE = "Source Downtime" },
    [99] = { BILLABLE = "False", MESSAGE = "Unknown Error" },
    [100] = { BILLABLE = "False", MESSAGE = "Internal Error" },
    [101] = { BILLABLE = "True", MESSAGE = "Success" },
    [102] = { BILLABLE = "False", MESSAGE = "Invalid ID number or combination of inputs" },
    [103] = { BILLABLE = "True", MESSAGE = "No records found for the given ID or combination of inputs" },
    [104] = { BILLABLE = "True", MESSAGE = "Max retries exceeded" },
    [105] = { BILLABLE = "True", MESSAGE = "Missing Consent" },
    [106] = { BILLABLE = "False", MESSAGE = "RC number is registered under more than one office" },
    [107] = { BILLABLE = "False", MESSAGE = "Invalid OTP" },
    [108] = { BILLABLE = "False", MESSAGE = "This is no longer active" },
    [109] = { BILLABLE = "False", MESSAGE = "Aadhaar suspended or cancelled." },
    [110] = { BILLABLE = "False", MESSAGE = "Source Unavailable" },
    [403] = { BILLABLE = "False", MESSAGE = "Request limit exceeded" },
    [401] = { BILLABLE = "False", MESSAGE = "Unauthorized" }
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
        local data = json.decode(full_body) or {}

        if ctx.var.responseFromHeader then
            data.x_trx_id = ctx.var.responseFromHeader
        end

        local request_body = ngx.req.get_body_data()

        -- core.log.warn("yyyyyyyyyyyyyyyyyyyyyy--anil", request_body)
        -- local input_data = {}
        -- if request_body then
        --     local ok, decoded = pcall(json.decode, request_body)
        --     if ok and type(decoded) == "table" then
        --         input_data = decoded
        --     end
        -- end

        -- local result = {
        --     input_udyam_number = input_data,
        --     transaction_id = generate_transaction_id(),
        --     request_timestamp = ngx.ctx.request_timestamp,
        --     response_timestamp = get_timestamp()
        -- }


            local uri = ngx.var.uri  
            core.log.warn("Extracted Udyam Number: ", uri)

            -- Extract UDYAM-DL-01-00572 from the full URI
            local udyam_number = uri:match("/UAN/(UDYAM%-%u%u%-%d+%-%d+)/") or "UNKNOWN"

            core.log.warn("Parsed Udyam Number: ", udyam_number)

            local result = {
                input_udyam_number = udyam_number,
                transaction_id = generate_transaction_id(),
                request_timestamp = ngx.ctx.request_timestamp,
                response_timestamp = get_timestamp()
            }


        -- Handle common errors
        if ngx.status == 401 then
            ngx.arg[1] = json.encode({ response_code = 401, response_message = "Bad credentials provided" })
            ngx.arg[2] = true
            return
        elseif ngx.status == 403 then
            ngx.arg[1] = json.encode({ response_code = 403, response_message = "Access Denied" })
            ngx.arg[2] = true
            return
        elseif ngx.status == 429 then
            ngx.arg[1] = json.encode({ response_code = 429, response_message = "Too many requests" })
            ngx.arg[2] = true
            return
        end

        local function clean(val)
            return (val and val ~= "" and val ~= "None" and val ~= "NA" and val ~= "N/A") and val or "NA"
        end

        local function rename(tbl, mapping)
            for old, new in pairs(mapping) do
                if tbl[old] then
                    tbl[new] = tbl[old]
                    tbl[old] = nil
                end
            end
        end

        local general_info_data = data["EnterpriseMaster"] or {}
        local unit_list = ((data["EnterpriseUnitMaster"] or {}).EnterpriseUnitLocation or {})
        local address_data = data["EnterpriseAddressMaster"] or {}
        local nic_data = ((data["EnterpriseLocationMaster"] or {}).NIC or {})
        local classification = ((data["EnterpriseClassificationMaster"] or {}).EnterpriseClassification or {})

        for _, unit in ipairs(unit_list) do
            rename(unit, {
                SrNo = "sn", UnitName = "unitName", FlatNo = "flat",
                BuildingName = "building", VillageOrTown = "villageTown", Block = "block",
                RoadOrStreetName = "road", City = "city", District = "district",
                State = "state", Pincode = "pin"
            })
        end

        for _, nic in ipairs(nic_data) do
            rename(nic, {
                Nic2Digit = "nic2Digit", Nic4Digit = "nic4Digit",
                Nic5Digit = "nic5Digit", ActivityType = "activity", AddedOn = "date"
            })
        end

        local general_info = {
            udyamregistrationnumber = clean(general_info_data["EnterpriseURN"]),
            name_of_enterprise = clean(general_info_data["EnterpriseName"]),
            type_of_enterprise = clean(general_info_data["EnterpriseType"]),
            major_activity = clean(general_info_data["MajorActivity"]),
            organisation_type = clean(general_info_data["OrganisationType"]),
            social_category = clean(general_info_data["SocialCategory"]),
            date_of_incorporation = clean(general_info_data["IncorporationDate"]),
            date_of_commencement_of_production_buisness = clean(general_info_data["DateOfCommencement"]),
            dic = clean(general_info_data["EnterpriseDIC"]),
            msmedi = clean(general_info_data["MSME-DI"]),
            date_of_udyam_registration = clean(general_info_data["RegistrationDate"])
        }

        local official_address = {
            flatdoor_block_no = clean(address_data["FlatOrDoorNo"]),
            name_of_permises_building = clean(address_data["PremisesOrBuildingName"]),
            village_town = clean(address_data["VillageOrTown"]),
            block = clean(address_data["Block"]),
            road_streetlane = clean(address_data["RoadOrStreetName"]),
            city = clean(address_data["City"]),
            state = clean(address_data["State"]),
            pin_code = clean(address_data["Pincode"]),
            district = clean(address_data["District"]),
            mobile = clean(address_data["ContactNo"]),
            email = clean(address_data["EmailID"])
        }

        result["result"] = {
            general_info = general_info,
            unit_details = unit_list,
            official_address = official_address,
            national_industry_classification_codes = nic_data,
            EnterpriseClassification = classification
        }

        if ngx.status == 200 then
            result.response_code = 101
        elseif ngx.status == 404 then
            result.response_code = 103
        elseif ngx.status == 400 then
            result.response_code = 102
        else
            result.response_code = 110
        end

        local bill = billable_dict[result.response_code] or { BILLABLE = "False", MESSAGE = "Unknown Response Code" }
        result.billable = bill.BILLABLE
        result.success = bill.BILLABLE == "True" and "True" or "False"
        result.response_message = bill.MESSAGE

        local order_map = {
            __self = {
                "transaction_id", "input_udyam_number", "success", "billable", "response_code",
                "response_message", "request_timestamp", "response_timestamp", "result"
            },
            result = {
                __self = {
                    "general_info", "unit_details", "official_address",
                    "national_industry_classification_codes", "EnterpriseClassification"
                },
                general_info = {
                    __self = {
                        "udyamregistrationnumber", "name_of_enterprise", "type_of_enterprise",
                        "major_activity", "organisation_type", "social_category",
                        "date_of_incorporation", "date_of_commencement_of_production_buisness",
                        "dic", "msmedi", "date_of_udyam_registration"
                    }
                },
                official_address = {
                    __self = {
                        "flatdoor_block_no", "name_of_permises_building", "village_town",
                        "block", "road_streetlane", "city", "state", "pin_code", "district",
                        "mobile", "email"
                    }
                },
                unit_details = {
                    __self = { "sn", "unitName", "flat", "building", "villageTown", "block", "road", "city", "district", "state", "pin" }
                },
                national_industry_classification_codes = {
                    __self = { "SrNo", "nic2Digit", "nic4Digit", "nic5Digit", "activity", "date" }
                },
                EnterpriseClassification = {
                    __self = { "SrNo", "ClaasificationYear", "EnterpriseType", "ClassificationDate" }
                }
            }
        }



      
      

            if result.response_code == 101 then
                local final_result = encode_in_order_recursive(result, order_map)

                -- 3. Log or assign to response
                -- core.log.warn("decoded_body in pipeline lua---anil", final_result)

                -- 4. Return the encoded string
                ngx.arg[1] = final_result
                ngx.arg[2] = true
            elseif result.response_code == 102 then
                result["result"] = {}
            elseif result.response_code == 103 then
                result["result"] = {}
            elseif result.response_code == 110 then
                result["result"] = {}

                
            else
                result["result"] = {}
            end

-- 2. Encode after all logic is done
        local final_result = encode_in_order_recursive(result, order_map)

        -- 3. Log or assign to response
        -- core.log.warn("decoded_body in pipeline lua---anil", final_result)

        -- 4. Return the encoded string
        ngx.arg[1] = final_result
        ngx.arg[2] = true
        
    end
end

return _M
