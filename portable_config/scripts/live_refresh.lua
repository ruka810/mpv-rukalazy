local mp = require 'mp'

local media_ready = false
local refreshing = false
local reload_started = false
local refresh_token = 0
local pending_settings = nil
local live_seek_token = 0
local live_seek_debounce_timer = nil
local live_seek_verify_timer = nil
local last_live_seek_warning = {message = nil, time = 0}

local LIVE_SOURCE_KINDS = {
    ['bilibili-live'] = true,
    ['youtube-live'] = true,
}
local CACHE_SEEK_TOLERANCE = 0.75
local REMOTE_SEEK_TOLERANCE = 3

local function clone(value)
    if type(value) ~= 'table' then return value end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = clone(item)
    end
    return copy
end

local function clear_refresh(message, succeeded)
    refreshing = false
    reload_started = false
    pending_settings = nil

    if succeeded == true then
        pcall(mp.commandv, 'script-message-to', 'bilibili_danmaku', 'live-refresh-loaded')
    elseif succeeded == false then
        pcall(mp.commandv, 'script-message-to', 'bilibili_danmaku', 'live-refresh-failed')
    end

    if message then mp.osd_message(message, 2) end
end

local function restore_visual_settings()
    if not pending_settings then return end

    local settings = pending_settings
    mp.set_property_native('vf', settings.vf)
    mp.set_property_native('glsl-shaders', settings.glsl_shaders)
end

local non_network_schemes = {
    file = true,
    bd = true,
    br = true,
    dvd = true,
    cdda = true,
    av = true,
    dvb = true,
    tv = true,
    mf = true,
    lavfi = true,
    memory = true,
}

local function is_network_url(value)
    if type(value) ~= 'string' then return false end

    local scheme = value:match('^([%a][%w+.-]*)://')
    if not scheme then return false end

    return not non_network_schemes[scheme:lower()]
end

local function is_network_media()
    return is_network_url(mp.get_property('path'))
        or is_network_url(mp.get_property('stream-open-filename'))
end

local function is_supported_live()
    return LIVE_SOURCE_KINDS[mp.get_property('user-data/web_source/kind', '')] == true
end

local function resume_live_playback()
    if is_supported_live() then mp.set_property_bool('pause', false) end
end

local function cancel_live_seek_timers()
    live_seek_token = live_seek_token + 1
    if live_seek_debounce_timer then
        live_seek_debounce_timer:kill()
        live_seek_debounce_timer = nil
    end
    if live_seek_verify_timer then
        live_seek_verify_timer:kill()
        live_seek_verify_timer = nil
    end
    return live_seek_token
end

local function warn_live_seek(message)
    local now = mp.get_time()
    if last_live_seek_warning.message == message and now - last_live_seek_warning.time < 0.75 then return end
    last_live_seek_warning = {message = message, time = now}
    mp.osd_message(message, 2)
end

local function cache_seekable_ranges()
    local state = mp.get_property_native('demuxer-cache-state')
    local source_ranges = type(state) == 'table' and state['seekable-ranges'] or nil
    local ranges = {}
    if type(source_ranges) ~= 'table' then return ranges end

    for _, range in ipairs(source_ranges) do
        local start_time = type(range) == 'table' and tonumber(range.start) or nil
        local end_time = type(range) == 'table' and tonumber(range['end']) or nil
        if start_time and end_time and end_time >= start_time then
            table.insert(ranges, {start = start_time, ['end'] = end_time})
        end
    end
    return ranges
end

local function target_in_cached_range(target, ranges)
    for _, range in ipairs(ranges) do
        if target >= range.start - CACHE_SEEK_TOLERANCE and target <= range['end'] + CACHE_SEEK_TOLERANCE then
            return true
        end
    end
    return false
end

local function seek_absolute(target)
    return pcall(mp.commandv, 'seek', target, 'absolute+exact')
end

local function restore_live_seek_origin(origin)
    local current = mp.get_property_number('time-pos')
    if origin and current and math.abs(current - origin) > CACHE_SEEK_TOLERANCE then
        seek_absolute(origin)
    end
end

local function verify_remote_live_seek(request, attempts)
    if request.token ~= live_seek_token then return end
    if mp.get_property_bool('seeking', false) and attempts < 4 then
        live_seek_verify_timer = mp.add_timeout(0.5, function()
            verify_remote_live_seek(request, attempts + 1)
        end)
        return
    end

    live_seek_verify_timer = nil
    local actual = mp.get_property_number('time-pos')
    if actual and math.abs(actual - request.target) <= REMOTE_SEEK_TOLERANCE then return end

    restore_live_seek_origin(request.origin)
    warn_live_seek('该直播时间点不可回退，已恢复原位置')
end

local function queue_remote_live_seek(target, origin)
    local token = cancel_live_seek_timers()
    local request = {token = token, target = target, origin = origin}
    live_seek_debounce_timer = mp.add_timeout(0.18, function()
        if request.token ~= live_seek_token then return end
        live_seek_debounce_timer = nil
        local ok = seek_absolute(request.target)
        if not ok then
            warn_live_seek('直播回退请求失败，已保持当前位置')
            return
        end
        live_seek_verify_timer = mp.add_timeout(1, function()
            verify_remote_live_seek(request, 0)
        end)
    end)
end

local function seek_live_timeline(target)
    target = tonumber(target)
    if not target then return end
    if not is_supported_live() then
        seek_absolute(target)
        return
    end

    local origin = mp.get_property_number('time-pos')
    if not origin then
        warn_live_seek('直播尚未就绪，无法回退')
        return
    end

    local ranges = cache_seekable_ranges()
    if target_in_cached_range(target, ranges) then
        cancel_live_seek_timers()
        seek_absolute(target)
        return
    end

    local seekable = mp.get_property_bool('seekable', false)
    local partially_seekable = mp.get_property_bool('partially-seekable', false)
    if partially_seekable then
        cancel_live_seek_timers()
        warn_live_seek('目标超出当前直播缓存范围')
        return
    end
    if not seekable then
        cancel_live_seek_timers()
        warn_live_seek('当前直播源不支持回退')
        return
    end

    queue_remote_live_seek(target, origin)
end

local function ensure_network_media()
    local path = mp.get_property('path')
    if not path or path == '' then
        mp.osd_message('当前没有正在播放的媒体', 2)
        return false
    end

    if not media_ready then
        mp.osd_message('媒体尚未就绪', 2)
        return false
    end

    if not is_network_media() then
        mp.osd_message('当前不是网络媒体', 2)
        return false
    end

    return true
end

local function sync_live()
    if not ensure_network_media() then return end

    -- 优先 seek 到当前缓存的最新位置，避免 drop-buffers 清空历史缓存。
    -- 对于支持 DVR 回看的直播源，这样同步后仍可回退到之前的内容。
    local ranges = cache_seekable_ranges()
    if #ranges > 0 then
        local latest = ranges[#ranges]['end']
        if latest then
            cancel_live_seek_timers()
            local ok = seek_absolute(latest)
            if ok then
                resume_live_playback()
                mp.osd_message('已同步到直播进度', 2)
                return
            end
        end
    end

    -- 无缓存范围或 seek 失败时回退到原来的 drop-buffers
    local ok = pcall(mp.commandv, 'drop-buffers')
    if not ok then
        mp.osd_message('同步直播进度失败', 2)
        return
    end

    resume_live_playback()
    mp.osd_message('正在同步直播进度', 2)
end

local function refresh_media()
    if refreshing then
        mp.osd_message('正在刷新媒体', 2)
        return
    end

    local path = mp.get_property('path')
    if not path or path == '' then
        mp.osd_message('当前没有正在播放的媒体', 2)
        return
    end

    pending_settings = {
        vf = clone(mp.get_property_native('vf') or {}),
        glsl_shaders = clone(mp.get_property_native('glsl-shaders') or {}),
        resume_live = is_supported_live(),
    }
    refreshing = true
    reload_started = false
    refresh_token = refresh_token + 1
    local token = refresh_token

    mp.osd_message('正在刷新媒体', 2)
    pcall(mp.commandv, 'script-message-to', 'bilibili_danmaku', 'live-refresh-start')
    local ok = pcall(mp.commandv, 'playlist-play-index', 'current')
    if not ok then
        clear_refresh('媒体刷新失败', false)
        return
    end

    mp.add_timeout(20, function()
        if refreshing and refresh_token == token then
            clear_refresh('媒体刷新超时', false)
        end
    end)
end

mp.register_event('start-file', function()
    media_ready = false
    if refreshing then reload_started = true end
end)

mp.register_event('file-loaded', function()
    media_ready = true
    if not refreshing then return end

    restore_visual_settings()
    if pending_settings and pending_settings.resume_live then mp.set_property_bool('pause', false) end
    clear_refresh('媒体已刷新', true)
end)

mp.register_event('end-file', function()
    media_ready = false
end)

mp.add_key_binding(nil, 'sync', sync_live)
mp.add_key_binding(nil, 'refresh', refresh_media)
mp.register_script_message('timeline-seek', seek_live_timeline)
