-- Preserve the original web page URL before ytdl_hook replaces it with the
-- resolved HLS/FLV stream.  Website-specific scripts consume this shared
-- context so they do not each race the ytdl_hook lifecycle independently.

local mp = require 'mp'
local utils = require 'mp.utils'

local context = nil
local generation = 0
local pending_direct_context = nil

local function classify_url(value)
    if type(value) ~= 'string' or value == '' then return nil end
    local host = value:match('^https?://([^/%?#:]+)')
    host = host and host:lower() or nil
    if not host then return nil end
    if host == 'live.bilibili.com' and (
        value:match('^https?://live%.bilibili%.com/%d+')
        or value:match('^https?://live%.bilibili%.com/blanc/%d+')
    ) then
        return 'bilibili-live'
    end
    if host == 'bilibili.com' or host:match('%.bilibili%.com$') then
        return 'bilibili-video'
    end
    if host == 'youtu.be' or host == 'youtube.com' or host:match('%.youtube%.com$') then
        return 'youtube-video'
    end
end

local function is_direct_media_url(value)
    -- A direct HTTP media URL must stay on the normal ffmpeg path.  Only
    -- extractor-backed webpages get the generic ytdl context below.
    local path = tostring(value or ''):match('^https?://[^/%?#]+([^?#]*)') or ''
    return path:lower():match('%.(3gp|aac|avi|flac|flv|m2ts|m3u8|m4a|m4v|mkv|mov|mp3|mp4|mpeg|mpg|oga|ogg|ogv|opus|ts|wav|webm|wmv)$') ~= nil
end

local function same_stream_url(left, right)
    return type(left) == 'string' and type(right) == 'string'
        and left:gsub('#.*$', '') == right:gsub('#.*$', '')
end

local function current_playlist_entry()
    local position = mp.get_property_number('playlist-pos', -1)
    local playlist = mp.get_property_native('playlist') or {}
    local item = position >= 0 and playlist[position + 1] or nil
    return item, item and item.id or nil
end

local function publish()
    if context then
        mp.set_property_native('user-data/web_source/context', context)
        mp.set_property('user-data/web_source/url', context.url or '')
        mp.set_property('user-data/web_source/kind', context.kind or '')
    else
        mp.set_property_native('user-data/web_source/context', {})
        mp.set_property('user-data/web_source/url', '')
        mp.set_property('user-data/web_source/kind', '')
    end
end

local function set_context(url, kind, entry_id, origin)
    if not url or not kind then return false end
    generation = generation + 1
    context = {
        url = url,
        kind = kind,
        entry_id = entry_id,
        generation = generation,
        origin = origin or 'on-load',
    }
    publish()
    return true
end

local function clear_context()
    context = nil
    generation = generation + 1
    publish()
end

local function ytdl_page_url()
    local result = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result')
    if type(result) ~= 'table' or type(result.stdout) ~= 'string' then return nil end
    local data = utils.parse_json(result.stdout)
    if type(data) ~= 'table' then return nil end
    for _, key in ipairs({'webpage_url', 'original_url', 'webpage_url_basename'}) do
        local value = data[key]
        local kind = classify_url(value)
        if kind == 'youtube-video' then
            local live_status = tostring(data.live_status or data.liveStatus or ''):lower()
            if data.is_live == true or live_status == 'is_live' or live_status == 'post_live' then
                kind = 'youtube-live'
            end
        end
        if kind then return value, kind, 'ytdl-json' end
        -- Keep arbitrary extractor pages distinct from direct HTTP media.
        -- `Generic` is mpv's direct-media fallback and has no webpage session
        -- context to preserve, so it deliberately stays on the raw path.
        if type(value) == 'string' and value:match('^https?://')
            and data.extractor_key ~= 'Generic' and not is_direct_media_url(value) then
            return value, 'ytdl-web', 'ytdl-json'
        end
    end
end

local function capture_source(event, origin)
    local item, current_entry_id = current_playlist_entry()
    -- `start-file` gives us the playlist id before ytdl_hook gets a chance to
    -- replace the visible filename with HLS/FLV. Prefer it over a later
    -- playlist snapshot whenever it is available.
    local entry_id = event and event.playlist_entry_id or current_entry_id
    local candidates = {
        mp.get_property('stream-open-filename') or '',
        item and (item.filename or item.path) or '',
        mp.get_property('path') or '',
    }
    for _, value in ipairs(candidates) do
        local kind = classify_url(value)
        if kind then
            set_context(value, kind, entry_id, origin or 'on-load')
            return
        end
    end

    -- A Bilibili live route is a short-lived signed FLV/HLS URL, so it cannot
    -- be recognized as a webpage on its own.  The quality picker marks the
    -- next direct load with its original page context before starting it.
    if pending_direct_context then
        for _, value in ipairs(candidates) do
            if same_stream_url(value, pending_direct_context.stream_url) then
                local pending = pending_direct_context
                pending_direct_context = nil
                set_context(pending.url, pending.kind, entry_id, 'quality-direct')
                return
            end
        end
    end

    -- During a quality-triggered reload mpv can briefly expose the previous
    -- resolved stream.  Keep the page context for the same playlist entry;
    -- a genuinely new entry is cleared instead.
    if context and context.entry_id ~= nil and entry_id ~= nil
        and tostring(context.entry_id) == tostring(entry_id) then
        publish()
        return
    end
    clear_context()
end

local function refresh_from_ytdl()
    local url, kind, origin = ytdl_page_url()
    if not url then return end
    local _, entry_id = current_playlist_entry()
    if context and context.url == url and tostring(context.entry_id) == tostring(entry_id) then
        return
    end
    set_context(url, kind, entry_id, origin)
end

-- `start-file` is the first reliable lifecycle point for URLs submitted to a
-- persistent mpv via umpv/IPC.  At this point it is still the page URL, not
-- the resolved live media URL. Hooks and yt-dlp JSON remain fallbacks for
-- unusual load paths.
mp.register_event('start-file', function(event) capture_source(event, 'start-file') end)
-- ytdl_hook uses priority 10. Capturing at priority 1 is an extra fallback
-- for direct loads that do not expose a usable start-file filename.
mp.add_hook('on_load', 1, function() capture_source(nil, 'on-load') end)
mp.add_hook('on_load_fail', 1, function() capture_source(nil, 'on-load-fail') end)
mp.register_event('file-loaded', function()
    mp.add_timeout(0, refresh_from_ytdl)
end)
mp.observe_property('idle-active', 'bool', function(_, value)
    if value then clear_context() end
end)
mp.register_event('shutdown', clear_context)

mp.register_script_message('prepare-direct-reload', function(json)
    local data = utils.parse_json(json or '')
    if type(data) ~= 'table' or type(data.url) ~= 'string' or type(data.kind) ~= 'string'
        or type(data.stream_url) ~= 'string' or not classify_url(data.url) then
        return
    end
    local pending = {url = data.url, kind = data.kind, stream_url = data.stream_url}
    pending_direct_context = pending
    mp.add_timeout(15, function()
        if pending_direct_context == pending then pending_direct_context = nil end
    end)
end)

capture_source(nil, 'startup')
