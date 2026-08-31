local mp = require 'mp'

local target = mp.command_native({ 'expand-path', '~~/scripts/bilibili_danmaku.lua' })
local reload_pending = false
local last_reload_at = -math.huge

local function renderer_is_healthy()
    local heartbeat = mp.get_property_native('user-data/bilibili_danmaku/heartbeat')
    local updated_at = type(heartbeat) == 'table' and tonumber(heartbeat.updated_at) or nil
    return updated_at ~= nil and mp.get_time() - updated_at < 2
end

local function restore_renderer()
    if reload_pending or renderer_is_healthy() then return end
    local now = mp.get_time()
    if now - last_reload_at < 2 then return end
    last_reload_at = now
    reload_pending = true
    mp.msg.warn('[bilibili_danmaku_watchdog] Reloading missing Bilibili danmaku renderer')
    local ok, err = pcall(mp.commandv, 'load-script', target)
    if not ok then mp.msg.warn('[bilibili_danmaku_watchdog] ' .. tostring(err)) end
    mp.add_timeout(0.25, function() reload_pending = false end)
end

mp.add_periodic_timer(0.5, restore_renderer)
mp.register_event('start-file', restore_renderer)
mp.register_event('file-loaded', function()
    mp.add_timeout(0.25, restore_renderer)
end)
