local core = require("apisix.core")
 
local str = require("resty.string")
 
local cjson = require "cjson.safe"
local resty_random = require "resty.random"
local cipher_lib = require("resty.openssl.cipher")
local base64_encode = ngx.encode_base64
local base64_decode = ngx.decode_base64

-- local regex = require('regex')
local ngx = ngx
local resty_random = require("resty.random")

local plugin_name = "AES_256_GCM"

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
            description = "AES-256 encryption key (GCM MODE) (must be 32 characters)"
        }
    },
    required = {"aes_key"}  -- AES key is required while applying plugin
}

-- Helper function to decrypt data
local function decrypt_data(aes_key, encrypted_data)
    local encrypted_raw = assert(base64_decode(encrypted_data ))
    
    -- Extract iv, ciphertext, and tag
    local iv_dec = encrypted_raw:sub(1, 12)
    local tag_dec = encrypted_raw:sub(-16)
    local ciphertext_dec = encrypted_raw:sub(13, -17)

    -- Init cipher for decryption
    local cipher_dec = assert(cipher_lib.new("aes-256-gcm"))
    assert(cipher_dec:init(aes_key, iv_dec, { is_encrypt = false }))

    -- Set GCM tag (must be before final)
    assert(cipher_dec:set_aead_tag(tag_dec))

    -- Decrypt
    local decrypted_data = assert(cipher_dec:update(ciphertext_dec))
    decrypted_data = decrypted_data .. assert(cipher_dec:final())
    return decrypted_data
end  


-- Helper function to encrypt data
local function encrypt_data(aes_key, plaintext_data)
        local iv = assert(resty_random.bytes(12))
        local json_data = cjson.encode(plaintext_data)

        -- === ENCRYPTION ===
        local cipher = assert(cipher_lib.new("aes-256-gcm"))
        assert(cipher:init(aes_key, iv, { is_encrypt = true }))

        -- Encrypt data
        local ciphertext = assert(cipher:update(json_data))
        ciphertext = ciphertext .. assert(cipher:final())

        -- Get GCM tag (16 bytes)
        local tag = assert(cipher:get_aead_tag(16))

        local encrypted = iv .. ciphertext .. tag
        local encrypted_b64 = base64_encode(encrypted)

        return encrypted_b64, nil
    
end

function isValidPAN(pan)
 
    if #pan == 10 then
        return true
    else
        return false
    end
end

local function is_valid_pan(pan)
    -- Trim leading and trailing spaces
    pan = pan:match("^%s*(.-)%s*$")

    -- Convert to uppercase
    pan = pan:upper()

    -- Define the PAN pattern (Lua-Compatible)
    local pan_pattern = "^%u%u%u[%u]%u%d%d%d%d%u$"

    -- Check if the PAN matches the pattern
    return pan:match(pan_pattern) ~= nil
end



function _M.check_body(ctx, required_key_1, required_key_2, json_body)
    -- If there is no request body, return an error
    if not json_body then
        return 400, { status = "102", message = "Request body is missing" }
    end

    -- Check for the first required key in the body
    if not json_body[required_key_1] then
        return 400, { status = "102", message = "Request body is missing" }
    end

    -- Check for the second required key in the body
    if not json_body[required_key_2] then
        return 400, { status = "102", message = "Request body is missing" }
    end

    local pan = json_body[required_key_1]
    if not is_valid_pan(pan) then
        return 400, { status = "102", message = "Invalid PAN format" }
    end

    local aadhaar = json_body[required_key_2]
    if aadhaar then
        -- Check if Aadhaar number is 4 digits long
        if #aadhaar ~= 4 then
            return 400, { status = "102", message = "Aadhaar number must be 4 digits" }
        end
    end

    -- If both keys exist and PAN is valid, allow the request to continue
    return 200, { status = "101", message = "Request is valid" }
end

-- Decrypt the request body
function _M.access(conf, ctx)
    -- Read request body
    ngx.req.read_body()
    local raw_body = ngx.req.get_body_data()
    if not raw_body then
        return core.response.exit(400, { error = "Invalid request body" })
    end

    local body, err = cjson.decode(raw_body)
    if not body or not body.encryptedReq then
        return core.response.exit(400, { status = "102", message = "Invalid request body format" })
    end

    -- Use provided AES key or default one
    local aes_key = conf.aes_key or DEFAULT_AES_KEY

    local status, decrypted_data = pcall(decrypt_data, aes_key, body.encryptedReq)
    
    -- Check if decryption failed
    if not status then
        -- Decryption failed, handle the error
        return core.response.exit(400, { status = "102", message = "Invalid request body format" })
    end

    local json_data, err = cjson.decode(decrypted_data)
    
    if json_data.pan then
        json_data.pan_number = json_data.pan
        json_data.pan = nil  -- Remove the original 'pan_number' key
    end

    if not json_data then
        core.log.warn("Starting decryption process...",cjson.encode(json_data))
        return core.response.exit(400, { error = err })
    end
     
    local required_key_1 = "pan_number"
    local required_key_2 = "aadhaar"
    ctx.var.decryptData =  json_data 
--     -- Check the request body for both keys
    local status, responses = _M.check_body(ctx, required_key_1, required_key_2,json_data)

    -- Set the decrypted JSON as the new request body
    ngx.req.set_body_data(cjson.encode(json_data))

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
        local newData = cjson.decode(chunk)
        
        if newData.input.pan_number then
            newData.input.pan = newData.input.pan_number
            newData.input.pan_number = nil  -- Remove the original 'pan_number' key
        end

        local encrypted_data, err = encrypt_data(aes_key, newData)
        if not encrypted_data then
            core.log.error("Encryption failed: ", err)
            return
        end


        local responseData = {
            encryptedRes = encrypted_data
 
        }  

        local finalResponse = cjson.encode(responseData)

        ngx.arg[1] = finalResponse
    end

    if eof then
        core.log.info("Response encryption completed successfully")
    end
end

return _M

