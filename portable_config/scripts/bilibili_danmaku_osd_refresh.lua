local mp = require 'mp'
local utils = require 'mp.utils'

local refresh_overlay = mp.create_osd_overlay('ass-events')
refresh_overlay.z = 1

local active = false
local refresh_timer = nil
local refresh_fps = 0
local nonce = 0
local observed_paused = false
local observed_vod_active = false
local observed_live_active = false
local frames = 0
local sample_started_at = nil
local actual_fps = 0
local instance_status_path = 'user-data/bilibili_danmaku/osd-refresh-instance-' .. mp.get_script_name()

local function target_fps()
    local fps = mp.get_property_number('display-fps', 0) or 0
    if fps <= 0 then fps = mp.get_property_number('estimated-display-fps', 0) or 0 end
    if fps <= 0 then fps = 60 end
    return math.min(240, math.max(1, math.floor(fps + 0.5)))
end

local function status(path)
    local value = mp.get_property(path, '')
    local decoded = value ~= '' and utils.parse_json(value) or nil
    return type(decoded) == 'table' and decoded or {}
end

local function has_moving_danmaku()
    local vod = status('user-data/bilibili_danmaku/vod-render-status')
    observed_vod_active = vod.active == true
    if observed_vod_active and not observed_paused then return true end
    local live = status('user-data/bilibili_danmaku/live-render-status')
    observed_live_active = live.active == true
    return observed_live_active
end

local function publish_status()
    mp.set_property_native(instance_status_path, {
        name = mp.get_script_name(),
        active = active,
        target_fps = active and refresh_fps or 0,
        actual_fps = actual_fps,
        driver = active and 'transparent-osd' or 'none',
        observed_vod_active = observed_vod_active,
        observed_live_active = observed_live_active,
        observed_paused = observed_paused,
    })
end

local function refresh_tick()
    if not active then return end
    nonce = nonce + 1
    -- A distinct but fully transparent payload forces a compositor redraw.
    refresh_overlay.res_x, refresh_overlay.res_y = 1, 1
    refresh_overlay.data = '{\\an7\\alpha&HFF\\1c&HFFFFFF\\3c&HFFFFFF}' .. tostring(nonce)
    refresh_overlay:update()

    local now = mp.get_time()
    sample_started_at = sample_started_at or now
    frames = frames + 1
    local elapsed = now - sample_started_at
    if elapsed >= 0.5 then
        actual_fps = frames / elapsed
        sample_started_at, frames = now, 0
        publish_status()
    end
end

local function stop_driver()
    active = false
    actual_fps = 0
    sample_started_at, frames = nil, 0
    if refresh_timer then
        refresh_timer:kill()
        refresh_timer = nil
    end
    refresh_overlay:remove()
end

local function start_driver(target)
    if refresh_timer and refresh_fps == target then return end
    if refresh_timer then refresh_timer:kill() end
    refresh_fps = target
    active = true
    actual_fps = 0
    sample_started_at, frames = nil, 0
    refresh_timer = mp.add_periodic_timer(1 / target, refresh_tick)
    refresh_tick()
end

local function update_driver()
    if has_moving_danmaku() then
        start_driver(target_fps())
    elseif active then
        stop_driver()
    end
    publish_status()
end

mp.observe_property('user-data/bilibili_danmaku/vod-render-status', 'native', update_driver)
mp.observe_property('user-data/bilibili_danmaku/live-render-status', 'native', update_driver)
mp.observe_property('pause', 'bool', function(_, value)
    observed_paused = value == true
    update_driver()
end)
mp.observe_property('display-fps', 'number', update_driver)
mp.observe_property('estimated-display-fps', 'number', update_driver)
mp.register_event('shutdown', stop_driver)
update_driver()
