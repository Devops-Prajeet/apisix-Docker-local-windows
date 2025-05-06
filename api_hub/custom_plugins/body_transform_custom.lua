--
local core              = require("apisix.core")
local xml2lua           = require("xml2lua")
local xmlhandler        = require("xmlhandler.tree")
local template          = require("resty.template")
local json              = require("cjson.safe")
local ngx               = ngx 
local decode_base64     = ngx.decode_base64
local req_set_body_data = ngx.req.set_body_data
local req_get_uri_args  = ngx.req.get_uri_args
local str_format        = string.format
local decode_args       = ngx.decode_args
local str_find          = core.string.find
local type              = type
local pcall             = pcall
local pairs             = pairs
local next              = next
local template          = require("resty.template")
template.escape         = function(s) return s end

local plugin_name = "body_transform_custom"


local transform_schema = {
    type = "object",
    properties = {
        input_format = { type = "string", enum = {"xml", "json", "encoded", "args"} },
        template = { type = "string" },
        template_is_base64 = { type = "boolean" },
        key_mappings = {
            type = "object",
            patternProperties = {
                [".+"] = { type = "string" }
            },
            additionalProperties = false
        }
    },
    required = {"template"},
}

local schema = {
    type = "object",
    properties = {
        request = transform_schema,
        response = transform_schema,
    },
    anyOf = {
        {required = {"request"}},
        {required = {"response"}},
        {required = {"request", "response"}},
    },
}


local _M = {
    version  = 0.1,
    priority = 1080,
    name     = "body_transform_custom",
    schema   = schema,
}


local function escape_xml(s)
    return s:gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub("'", "&apos;")
        :gsub('"', "&quot;")
end



local function escape_json(s)
    return core.json.encode(s)
end


local function remove_namespace(tbl)
    for k, v in pairs(tbl) do
        if type(v) == "table" and next(v) == nil then
            v = ""
            tbl[k] = v
        end
        if type(k) == "string" then
            local newk = k:match(".*:(.*)")
            if newk then
                tbl[newk] = v
                tbl[k] = nil
            end
            if type(v) == "table" then
                remove_namespace(v)
            end
        end
    end
    return tbl
end

local function transform_keys(obj, mappings)
    if type(obj) ~= "table" or not mappings then
        return obj
    end
    local new_json = json.new()
    new_json.encode_sparse_array(true, 1, 1)
    core.log.warn("mapping new ", new_json.encode(obj), new_json.encode(mappings))
    local new_obj = {}
    for k, v in pairs(obj) do
        local new_key = mappings[k] or k
        if type(v) == "table" then
            new_obj[new_key] = transform_keys(v, mappings)
        else
            new_obj[new_key] = v
        end
    end
    return new_obj
end

local decoders = {
    xml = function(data)
        local handler = xmlhandler:new()
        local parser = xml2lua.parser(handler)
        local ok, err = pcall(parser.parse, parser, data)
        if ok then
            return remove_namespace(handler.root)
        else
            return nil, err
        end
    end,
    json = function(data)
        return core.json.decode(data)
    end,
    encoded = function(data)
        return decode_args(data)
    end,
    args = function()
        return req_get_uri_args()
    end,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function auto_json_wrap(obj)
    if type(obj) ~= "table" then
        return obj
    end

    local mt = {
        __tostring = function(t)
            local ok, json = pcall(core.json.encode, t)
            return ok and json or "null"
        end
    }

    for k, v in pairs(obj) do
        if type(v) == "table" then
            obj[k] = auto_json_wrap(v)
        end
    end

    return setmetatable(obj, mt)
end




local function transform(conf, body, typ, ctx, request_method)
    local out = {}
    local format = conf[typ].input_format or "json"
    if body or request_method == "GET" then
        local err
        if format then
            out, err = decoders[format](body)
            if not out then
                err = str_format("%s body decode: %s", typ, err)
                return nil, 400, err
            end
        else
            core.log.warn("no input format to parse ", typ, " body")
        end
    end
    
    if conf[typ].key_mappings then
        out = transform_keys(out, conf[typ].key_mappings)
    end

    local text = conf[typ].template
    if (conf[typ].template_is_base64 or (format and format ~= "encoded" and format ~= "args")) then
        text = decode_base64(text) or text
    end

    -- ✅ Disable HTML escaping in templates
    -- template.escape = nil  -- ✅ Disable auto escaping
    -- template.escape = function(s) return s end
    local new_json = json.new()
    new_json.encode_sparse_array(true, 1, 1)

    local ok, render = pcall(template.compile, text)
    if not ok then
        local err = render
        err = str_format("%s template compile: %s", typ, err)
        core.log.error(err)
        return nil, 503, err
    end

    out = auto_json_wrap(out)
    out._ctx = ctx
    out._body = body
    out._escape_xml = escape_xml
    out._escape_json = escape_json

    local ok, render_out = pcall(render, out)
    if not ok then
       
        local err = str_format("%s gx$119Id rendering: %s", typ, render_out)
        return nil, 503, err
    end

    return render_out
end



local function set_input_format(conf, typ, ct, method)
    if method == "GET" then
        conf[typ].input_format = "args"
    end
    if conf[typ].input_format == nil and ct then
        if ct:find("text/xml") then
            conf[typ].input_format = "xml"
        elseif ct:find("application/json") then
            conf[typ].input_format = "json"
        elseif str_find(ct:lower(), "application/x-www-form-urlencoded", nil, true) then
            conf[typ].input_format = "encoded"
        end
    end
end


function _M.rewrite(conf, ctx)
    if conf.request then
        local request_method  = ngx.var.request_method
        conf = core.table.deepcopy(conf)
        ctx.body_transformer_conf = conf
        local body = core.request.get_body()
        set_input_format(conf, "request", ctx.var.http_content_type, request_method)
        local out, status, err = transform(conf, body, "request", ctx, request_method)
        if not out then
            return status, { message = err }
        end
        req_set_body_data(out)
    end
end


function _M.header_filter(conf, ctx)
    if conf.response then
        if not ctx.body_transformer_conf then
            conf = core.table.deepcopy(conf)
            
            ctx.body_transformer_conf = conf
            ctx.body_transformer_conf.input_data = "json"
            local new_json = json.new()
             new_json.encode_sparse_array(true, 1, 1)
        end
        set_input_format(conf, "response", ngx.header.content_type)
        core.response.clear_header_as_body_modified()
    end
end


function _M.body_filter(_, ctx)
    local conf = ctx.body_transformer_conf
    if conf.response then
        local body = core.response.hold_body_chunk(ctx)
        local responseCode = tonumber(body.response_code)
        if ngx.arg[2] == false and not body then
            return
        end
        
        if ngx.status == 400 then
            -- Only keep two keys (example: code and message)
            local template_text = conf.response.template
             
            -- Replace the "result" field manually (smart string replace)
            template_text = template_text:gsub('"result"%s*:%s*%b{}', '"result": {}')
            
            -- Update the template in conf
            conf.response.template = template_text
        end
        
        body = core.json.decode(body)

        if responseCode == 103 then
            -- Only keep two keys (example: code and message)
            local template_text = conf.response.template
             
            -- Replace the "result" field manually (smart string replace)
            template_text = template_text:gsub('"result"%s*:%s*%b{}', '"result": {}')
            
            -- Update the template in conf
            conf.response.template = template_text

        elseif responseCode == 110 then
            -- Only keep two keys (example: code and message)
            local template_text = conf.response.template
             
            -- Replace the "result" field manually (smart string replace)
            template_text = template_text:gsub('"result"%s*:%s*%b{}', '"result": {}')
            
            -- Update the template in conf
            conf.response.template = template_text
        end
        
        body = core.json.encode(body)
        
        local out = transform(conf, body, "response", ctx)
        local decoded_out, err = core.json.decode(out)
        if not decoded_out then
            core.log.error("failed to decode transformed output: ", err)
            return
        end

        -- Check for 401 status
        if ngx.status == 401 then
            -- Only keep two keys (example: code and message)
            local filtered_output = {
                response_code = decoded_out.response_code,
                response_message = decoded_out.response_message,
            }
            out = core.json.encode(filtered_output)
        end
        
        ngx.arg[1] = out
    end
end


return _M
