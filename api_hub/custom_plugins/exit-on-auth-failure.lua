local plugin_name = "exit-on-auth-failure"
local core = require("apisix.core")
local ngx = ngx

local schema = {
    type = "object",
    properties = {}
}

local _M = {
    version = 0.1,
    priority = 1081,  -- Must be higher than body-transformer (1080)
    name = plugin_name,
    schema = schema,
    scope = "global",
}

-- Use `ngx.shared` dictionary for persistent storage
local plugin_store = ngx.shared.plugin_store

function _M.access(conf, ctx)
    -- Check if authentication failed
    if ngx.status == 401 then
        core.log.error(plugin_name .. ": Authentication failed. Blocking request.")
        return ngx.exit(401)  -- ✅ Properly exit in `access` phase
    end
end

function _M.body_filter(conf, ctx)
    if ngx.status == 401 then
        -- Authentication failed (disable body-transformer) but DO NOT EXIT
        for i, plugin in ipairs(ctx.plugins) do
            if plugin.name and plugin.name == "body-transformer" then
                -- Store the original plugin functions and conf persistently in `ngx.shared`
                local plugin_data = {
                    rewrite = plugin.rewrite,
                    body_filter = plugin.body_filter,
                    conf = ctx.body_transformer_conf
                }

                -- Store in shared dictionary (persisted across requests)
                local success, err = plugin_store:set("body_transformer_backup", core.json.encode(plugin_data))
                if not success then
                    core.log.error(plugin_name .. ": Failed to store body-transformer backup. Error: " .. err)
                end

                -- Disable body-transformer for this request (without exiting)
                core.log.error(plugin_name .. ": Disabling body-transformer due to 401 status.")
                plugin.rewrite = nil
                plugin.body_filter = nil
                ctx.body_transformer_conf = nil  -- ✅ Prevent execution issues
            end
        end
    else
        -- Restore body-transformer if authentication was successful
        local stored_data, err = plugin_store:get("body_transformer_backup")

        if stored_data then
            local plugin_backup = core.json.decode(stored_data)
            for i, plugin in ipairs(ctx.plugins) do
                if plugin.name and plugin.name == "body-transformer" then
                    core.log.warn(plugin_name .. ": Restoring body-transformer plugin functions.")

                    -- Restore plugin functions
                    plugin.rewrite = plugin_backup.rewrite
                    plugin.body_filter = plugin_backup.body_filter

                    -- **Ensure `conf` is restored properly**
                    ctx.body_transformer_conf = plugin_backup.conf or { response = true }  -- ✅ Prevent `nil` conf

                    -- Log restoration
                    core.log.warn(plugin_name .. ": Successfully restored body-transformer.")

                    -- Clean up storage after restoring
                    plugin_store:delete("body_transformer_backup")
                end
            end
        else
            core.log.error(plugin_name .. ": No body-transformer backup found. Error: " .. (err or "unknown"))
        end
    end
end

return _M
