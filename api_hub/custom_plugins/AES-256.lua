local core = require("apisix.core")
local aes = require("resty.aes")
local str = require("resty.string")
local json = require("cjson.safe")
-- local regex = require('regex')
local ngx = ngx
local resty_random = require("resty.random")

local plugin_name = "aes_proxy"

local _M = {
    version = 0.1,
    priority = 1000, -- Ensure execution before forwarding request
    name = plugin_name
}

-- Default AES-256 key (must be 32 bytes)
-- local DEFAULT_AES_KEY = "7B2D624002345F19EB3702A98D2E4B1S" -- 32-byte key

-- Plugin schema for validation
_M.schema = {
    type = "object",
    properties = {
        aes_key = {
            type = "string",
            minLength = 32,
            maxLength = 32,
            description = "AES-256 encryption key (must be 32 characters)"
        }
    },
    required = {"aes_key"}  -- AES key is required while applying plugin
}

-- Helper function to decrypt data
local function decrypt_data(aes_key, encrypted_data)
    local encrypted_data_bytes = ngx.decode_base64(encrypted_data)
    if not encrypted_data_bytes then
        core.log.error("Base64 decoding failed")
        return nil, "Base64 decoding failed"
    end

    local iv = encrypted_data_bytes:sub(1, 16)
    local ciphertext = encrypted_data_bytes:sub(17)

    if #aes_key ~= 32 then
        return nil, "Invalid AES key length. Expected 32 bytes."
    end

    if #iv ~= 16 then
        return nil, "Invalid IV length. Expected 16 bytes."
    end

    local aes_instance = aes:new(aes_key, nil, aes.cipher(256, "cbc"), { iv = iv })
    if not aes_instance then
        return nil, "Failed to create AES instance"
    end

    local decrypted_data = aes_instance:decrypt(ciphertext)
    if not decrypted_data then
        return nil, "Decryption failed"
    end

    return decrypted_data, nil
end

-- Helper function to encrypt data
local function encrypt_data(aes_key, plaintext_data)
    local iv = resty_random.bytes(16)
    if not iv then
        return nil, "Failed to generate IV"
    end

    local aes_instance = aes:new(aes_key, nil, aes.cipher(256, "cbc"), { iv = iv })
    if not aes_instance then
        return nil, "Failed to create AES instance"
    end

    local ciphertext = aes_instance:encrypt(plaintext_data)
    if not ciphertext then
        return nil, "Encryption failed"
    end

    local encrypted_data = ngx.encode_base64(iv .. ciphertext)
    return encrypted_data, nil
end

function isValidPAN(pan)
 
    if #pan == 10 then
        return true
    else
        return false
    end
end

function _M.check_body(ctx, required_key_1, required_key_2,json_body)
    -- ngx.req.read_body()
    -- local body = ngx.req.get_body_data()
     

    -- If there is no request body, return an error
    if not json_body then
        return 400, { message = "Request body is missing" }
    end

    local json_body = json_body
    -- Check for the first required key in the body
    -- if not json_body[required_key_1] then
    --     return 400, { status =  "102" }
    -- end

    -- -- Check for the second required key in the body
    -- if not json_body[required_key_2] then
    --     return 400, { status =  "102" }
    -- end

    local pan = json_body[required_key_1]
    if not isValidPAN(pan) then
        return 400, { status =  "3" }
    end



    -- If both keys exist, allow the request to continue
    return 200
end

-- Decrypt the request body
function _M.access(conf, ctx)
    -- Read request body
    ngx.req.read_body()
    local raw_body = ngx.req.get_body_data()
    if not raw_body then
        return core.response.exit(400, { error = "Invalid request body" })
    end

    local body, err = json.decode(raw_body)
    if not body or not body.encryptedReq then
        return core.response.exit(400, { error = "Invalid request body format" })
    end

    -- Use provided AES key or default one
    local aes_key = conf.aes_key or DEFAULT_AES_KEY

    local decrypted_data, err = decrypt_data(aes_key, body.encryptedReq)
    if not decrypted_data then
        return core.response.exit(400, { error = err })
    end

    local json_data, err = json.decode(decrypted_data)
    if not json_data then
        core.log.warn("Starting decryption process...",json.encode(json_data))
        return core.response.exit(400, { error = err })
    end

    local required_key_1 = "pan"
    local required_key_2 = "aadhaar"

--     -- Check the request body for both keys
    local status, responses = _M.check_body(ctx, required_key_1, required_key_2,json_data)

    

    -- Set the decrypted JSON as the new request body
    ngx.req.set_body_data(json.encode(json_data))

    if status ~= 200 then
        -- core.log.warn("things not working perfeclty",status,responses)
        return core.response.exit(status, responses)
    end
end

-- Adjust headers in the header_filter phase
function _M.header_filter(conf, ctx)
    ngx.header["Content-Length"] = nil
end

-- Encrypt the response body in chunks
function _M.body_filter(conf, ctx)
    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    if chunk ~= "" then
        -- Use provided AES key or default one
        local aes_key = conf.aes_key or DEFAULT_AES_KEY

        local encrypted_data, err = encrypt_data(aes_key, chunk)
        if not encrypted_data then
            core.log.error("Encryption failed: ", err)
            return
        end


        local responseData = {
            encryptedRes = encrypted_data
 
        }  

        local finalResponse = json.encode(responseData)

        ngx.arg[1] = finalResponse
    end

    if eof then
        core.log.info("Response encryption completed successfully")
    end
end

return _M

