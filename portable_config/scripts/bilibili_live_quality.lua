-- Website quality chooser for Bilibili and YouTube.
--
-- The menu deliberately uses the extractor's current format inventory.  It
-- keeps Bilibili's own quality names for Bilibili, while YouTube rows show the
-- decoded characteristics that distinguish otherwise similar formats.

local mp = require 'mp'
local utils = require 'mp.utils'

local bridge = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/publish_v13/mpv-cookie-bridge.exe' })

local source_url = nil
local source_kind = nil
local source_entry_id = nil
local source_generation = 0
local selected_format_id = nil -- nil means "自动：最高可用"
local selected_selector = nil
local selected_actual_id = nil
local expected_selector = nil
-- nil means follow the codec that is currently being decoded. An explicit
-- value is kept only for the current web media item.
local selected_live_codec = nil
-- These only shape the Bilibili menu.  They must never change playback until
-- the user explicitly selects one of the matching routes.
local filter_codec = nil
local filter_quality = nil
local restore_ytdl_format = nil
local pending_reload_url = nil
local reload_start_seen = false
local reload_uses_direct_route = false
local reload_token = 0
local pending_playlist_swap = nil
local query_abort = nil
local query_timeout = nil
local query_serial = 0
local latest_formats = nil
local AUTO_SELECTOR = 'bestvideo*+bestaudio/best'
local auto_dvr_probe_abort = nil
local auto_dvr_probe_key = nil
local AUTO_DVR_MINIMUM_WINDOW = 120

local function shared_source()
    local data = mp.get_property_native('user-data/web_source/context')
    if type(data) ~= 'table' or type(data.url) ~= 'string' or data.url == '' then return nil end
    if type(data.kind) ~= 'string' or data.kind == '' then return nil end
    return data
end

local function ytdl_info()
    local result = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result')
    if type(result) ~= 'table' or type(result.stdout) ~= 'string' then return nil end
    return utils.parse_json(result.stdout)
end

local function youtube_is_live()
    local info = ytdl_info()
    local status = info and (info.live_status or info.liveStatus)
    if status == 'is_live' or status == 'is_upcoming' or status == 'post_live' then return true end
    return mp.get_property_native('duration') == nil
end

local function title_for_kind(kind)
    return ({
        ['bilibili-video'] = 'Bilibili 视频画质',
        ['bilibili-live'] = 'Bilibili 直播画质',
        ['youtube-video'] = 'YouTube 视频画质',
        ['youtube-live'] = 'YouTube 直播画质',
    })[kind] or '流画质'
end

local function clear_source()
    if auto_dvr_probe_abort then auto_dvr_probe_abort(); auto_dvr_probe_abort = nil end
    auto_dvr_probe_key = nil
    source_url, source_kind, source_entry_id, latest_formats = nil, nil, nil, nil
    selected_format_id, selected_selector, selected_actual_id = nil, nil, nil
    expected_selector, selected_live_codec, filter_codec, filter_quality = nil, nil, nil, nil
    pending_playlist_swap, reload_uses_direct_route = nil, false
    mp.set_property_native('user-data/web_quality/is-web', false)
    mp.set_property('user-data/web_quality/kind', '')
    mp.set_property_native('user-data/bilibili_live_quality/is-live', false)
end

local function publish_source()
    mp.set_property_native('user-data/web_quality/is-web', source_url ~= nil)
    mp.set_property('user-data/web_quality/kind', source_kind or '')
    -- Compatibility for callers from the earlier Bilibili-only implementation.
    mp.set_property_native('user-data/bilibili_live_quality/is-live', source_kind == 'bilibili-live')
end

local function remember_source()
    local previous_url, previous_kind, previous_entry_id = source_url, source_kind, source_entry_id
    source_generation = source_generation + 1
    local source = shared_source()
    local discovered_url, discovered_kind = source and source.url or nil, source and source.kind or nil
    local playlist_entry_id = source and source.entry_id or nil

    -- yt-dlp can replace every observable URL with an HLS/FLV endpoint while
    -- retaining the same playlist entry.  Keep the original page URL through
    -- that transition (and through a quality-triggered reload) instead of
    -- falling back to uosc's generic resolution ladder.
    local same_entry = previous_entry_id ~= nil and playlist_entry_id ~= nil
        and tostring(previous_entry_id) == tostring(playlist_entry_id)
    local source_changed = discovered_url and (discovered_url ~= previous_url or discovered_kind ~= previous_kind)
    if discovered_url then
        source_url, source_kind = discovered_url, discovered_kind
        source_entry_id = playlist_entry_id
        if source_changed then
            if auto_dvr_probe_abort then auto_dvr_probe_abort(); auto_dvr_probe_abort = nil end
            auto_dvr_probe_key = nil
            latest_formats = nil
            if discovered_url ~= pending_reload_url then
                selected_live_codec, filter_codec, filter_quality = nil, nil, nil
            end
        end
    elseif previous_url and (same_entry or previous_url == pending_reload_url) then
        source_url, source_kind, source_entry_id = previous_url, previous_kind, previous_entry_id
    else
        source_url, source_kind, source_entry_id, latest_formats = nil, nil, nil, nil
    end

    -- Preserve one explicit selection only through the reload that it caused.
    if source_url ~= pending_reload_url and (source_url ~= previous_url or not same_entry) then
        selected_format_id, selected_selector, selected_actual_id = nil, nil, nil
    elseif source_url == pending_reload_url then
        reload_start_seen = true
    elseif source_url == nil or (previous_kind and source_kind ~= previous_kind) then
        selected_format_id, selected_selector, selected_actual_id = nil, nil, nil
    end

    publish_source()
end

local function proxy_args(args)
    local options = mp.get_property_native('ytdl-raw-options') or {}
    if type(options.proxy) == 'string' and options.proxy ~= '' then
        table.insert(args, '--proxy')
        table.insert(args, options.proxy)
    end
end

local function is_real_video(format)
    if type(format) ~= 'table' or type(format.format_id) ~= 'string' or format.format_id == '' then return false end
    if not format.url then return false end
    return (type(format.vcodec) == 'string' and format.vcodec ~= '' and format.vcodec ~= 'none')
        or tonumber(format.height) ~= nil
end

local function codec_name(format)
    local value = format.vcodec
    if type(value) ~= 'string' or value == '' or value == 'none' then value = format.acodec end
    if type(value) ~= 'string' or value == '' or value == 'none' then return nil end
    return value:match('^([%w_%-]+)') or value
end

local LIVE_CODEC_ORDER = {'av1', 'hevc', 'avc'}
local LIVE_CODEC_RANK = {av1 = 1, hevc = 2, avc = 3}
local LIVE_CODEC_LABELS = {
    av1 = 'AV1',
    hevc = 'HEVC (H.265)',
    avc = 'AVC (H.264)',
}

local function normalize_live_codec(value)
    value = tostring(value or ''):lower()
    if value:find('av1', 1, true) or value:find('av01', 1, true) then return 'av1' end
    if value:find('hevc', 1, true) or value:find('h265', 1, true)
        or value:find('hev1', 1, true) or value:find('hvc1', 1, true) then return 'hevc' end
    if value:find('avc', 1, true) or value:find('h264', 1, true) then return 'avc' end
    return nil
end

local function decoded_live_codec()
    local params = mp.get_property_native('video-params') or mp.get_property_native('video-out-params') or {}
    return normalize_live_codec(params.codec or params['codec-name'])
end

local function bilibili_name(format)
    local note = format.format_note
    if type(note) == 'string' and note ~= '' and note ~= 'None' then return note end
    local name = format.format
    -- Bilibili VOD normally puts the real tier name in `format`, e.g.
    -- "1080P 高码率" or "4K".  Falling back to height first discarded that
    -- useful distinction and made separate Bilibili tiers look fabricated.
    if type(name) == 'string' and name ~= '' and name ~= 'unknown' then
        name = name:gsub('^' .. format.format_id:gsub('([^%w])', '%%%1') .. '%s*%-%s*', '')
        if name ~= '' and name ~= 'unknown' then return name end
    end
    if tonumber(format.height) then return tostring(format.height) .. 'P' end
    return '线路 ' .. format.format_id
end

local function youtube_name(format)
    local height, fps = tonumber(format.height), tonumber(format.fps)
    local name = height and (tostring(height) .. 'p') or (format.format_note or format.format_id)
    if fps and fps > 0 then name = name .. tostring(math.floor(fps + 0.5)) end
    return name
end

local function format_selector(format)
    local id = format.format_id
    -- Bilibili live extractor entries are complete HLS/FLV routes even when
    -- it cannot report `acodec`.  Adding `+bestaudio` makes yt-dlp reject the
    -- requested route and silently fall back to a different quality.
    if source_kind == 'bilibili-live' then return id end
    if type(format.acodec) ~= 'string' or format.acodec == '' or format.acodec == 'none' then
        return id .. '+bestaudio/best'
    end
    return id
end

local function detail_for(format, kind, ordinal)
    local detail = {}
    local codec = codec_name(format)
    if codec then table.insert(detail, codec) end
    local fps = tonumber(format.fps)
    if fps and fps > 0 then table.insert(detail, tostring(math.floor(fps + 0.5)) .. 'fps') end
    if kind:match('youtube') and type(format.dynamic_range) == 'string' and format.dynamic_range ~= '' then
        table.insert(detail, format.dynamic_range)
    end
    if type(format.protocol) == 'string' and format.protocol ~= '' then table.insert(detail, format.protocol) end
    if ordinal then table.insert(detail, '线路 ' .. ordinal) end
    return detail
end

local function bilibili_live_tier(format)
    local id = tostring(format.format_id or ''):lower()
    if id:find('source_true_color', 1, true) then return 900 end
    if id:find('dolby', 1, true) then return 850 end
    if id:find('4k', 1, true) then return 800 end
    if id:find('2k', 1, true) then return 700 end
    if id:find('source', 1, true) or id:find('origin', 1, true) then return 600 end
    if id:find('blue_ray', 1, true) then return 500 end
    if id:find('ultra_high', 1, true) then return 400 end
    if id:find('high_res', 1, true) then return 300 end
    if id:find('high', 1, true) then return 200 end
    if id:find('low', 1, true) then return 100 end
    return 0
end

local function is_hls_route(format)
    local protocol = tostring(format.protocol or ''):lower()
    local ext = tostring(format.ext or ''):lower()
    return protocol:find('m3u8', 1, true) ~= nil or ext == 'fmp4' or ext == 'm3u8'
end

local function live_route_protocol(format)
    return is_hls_route(format) and 'HLS' or 'FLV'
end

local function live_route_host(format)
    local url = tostring(format.url or '')
    local host = url:match('^https?://([^/%?#:]+)')
    return host and host:lower() or '未知 CDN'
end

local function current_route_is_hls()
    local path = tostring(mp.get_property('path') or ''):lower()
    return path:find('.m3u8', 1, true) ~= nil
end

local function current_live_transport()
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'video' and track.selected then
            local title = tostring(track.title or ''):lower()
            if title:find('fmp4', 1, true) or title:find('m3u8', 1, true) then return 'HLS' end
            if title:find('flv', 1, true) then return 'FLV' end
        end
    end
    return current_route_is_hls() and 'HLS' or nil
end

local function live_route_is_better(candidate, current)
    if not current then return true end
    local want_hls = current_live_transport() == 'HLS'
    local candidate_hls, current_hls = is_hls_route(candidate), is_hls_route(current)
    if candidate_hls ~= current_hls then
        return want_hls and candidate_hls or (not want_hls and not candidate_hls)
    end
    local candidate_protocol = tostring(candidate.protocol or candidate.ext or '')
    local current_protocol = tostring(current.protocol or current.ext or '')
    if candidate_protocol ~= current_protocol then return candidate_protocol < current_protocol end
    return tostring(candidate.format_id or '') < tostring(current.format_id or '')
end

-- Return every discovered route grouped by Bilibili quality tier and codec.
-- Individual routes remain selectable; `format` is only the automatic choice
-- for a tier.
local function live_codec_groups(formats)
    local groups = {}
    for _, format in ipairs(formats or {}) do
        if is_real_video(format) then
            local codec = normalize_live_codec(format.vcodec)
            if codec then
                local name = bilibili_name(format)
                groups[codec] = groups[codec] or {}
                local group = groups[codec][name]
                if not group then
                    group = {
                        codec = codec,
                        name = name,
                        tier = bilibili_live_tier(format),
                        routes = {},
                        format = nil,
                    }
                    groups[codec][name] = group
                end
                table.insert(group.routes, format)
                if live_route_is_better(format, group.format) then group.format = format end
            end
        end
    end
    return groups
end

local function live_route_rows(row)
    local routes = {}
    for _, format in ipairs(row.routes or {}) do table.insert(routes, format) end
    table.sort(routes, function(a, b)
        local ap, bp = live_route_protocol(a), live_route_protocol(b)
        if ap ~= bp then return ap < bp end
        local ah, bh = live_route_host(a), live_route_host(b)
        if ah ~= bh then return ah < bh end
        return tostring(a.format_id or '') < tostring(b.format_id or '')
    end)
    return routes
end

local function live_codec_rows(groups, codec)
    local rows = {}
    for _, row in pairs(groups[codec] or {}) do table.insert(rows, row) end
    table.sort(rows, function(a, b)
        if a.tier ~= b.tier then return a.tier > b.tier end
        return a.name < b.name
    end)
    return rows
end

local function effective_live_codec(groups)
    if selected_live_codec and groups[selected_live_codec] then return selected_live_codec end
    local decoded = decoded_live_codec()
    if decoded and groups[decoded] then return decoded end
    for _, codec in ipairs(LIVE_CODEC_ORDER) do
        if groups[codec] then return codec end
    end
    return nil
end

local function codec_title(codec)
    return LIVE_CODEC_LABELS[codec] or tostring(codec or '未知编码')
end

local function live_auto_format()
    local groups = live_codec_groups(latest_formats)
    local codec = effective_live_codec(groups)
    local row = codec and live_codec_rows(groups, codec)[1] or nil
    return row and row.format or nil
end

local function live_auto_hls_format(formats)
    local groups = live_codec_groups(formats)
    local codec = effective_live_codec(groups)
    if not codec then return nil end

    for _, row in ipairs(live_codec_rows(groups, codec)) do
        for _, route in ipairs(live_route_rows(row)) do
            if is_hls_route(route) then return route end
        end
    end
end

local function live_auto_flv_format(formats)
    local groups = live_codec_groups(formats)
    local codec = effective_live_codec(groups)
    if not codec then return nil end

    for _, row in ipairs(live_codec_rows(groups, codec)) do
        for _, route in ipairs(live_route_rows(row)) do
            if not is_hls_route(route) then return route end
        end
    end
end

local function live_format_for_selector(selector)
    for _, format in ipairs(latest_formats or {}) do
        if is_real_video(format) and format_selector(format) == selector then return format end
    end
end

local function live_format_is_active(format)
    return selected_actual_id and selected_actual_id == format.format_id
        or (not selected_actual_id and selected_selector == format_selector(format))
end

local function live_route_items(row)
    local items = {}
    for index, format in ipairs(live_route_rows(row)) do
        local protocol, host = live_route_protocol(format), live_route_host(format)
        table.insert(items, {
            title = protocol .. ' · ' .. host,
            hint = '线路 ' .. tostring(index),
            value = format_selector(format),
            active = live_format_is_active(format),
        })
    end
    return items
end

local function live_quality_items(groups, codec)
    local items = {}
    for _, row in ipairs(live_codec_rows(groups, codec)) do
        table.insert(items, {
            title = row.name,
            hint = tostring(#row.routes) .. ' 条线路 · ▶',
            items = live_route_items(row),
        })
    end
    return items
end

local function bilibili_quality_rank(format, name)
    local live_rank = bilibili_live_tier(format)
    if live_rank > 0 then return live_rank end

    local lower = tostring(name or ''):lower()
    -- yt-dlp's Bilibili entries do not consistently expose `height`.  The
    -- quality name is therefore the reliable source for regular VOD tiers.
    -- Keep the numeric part as the primary order so 1080P, 720P, 480P and
    -- 360P never fall back to Lua's unordered table iteration.
    local height = tonumber(lower:match('(%d+)%s*p'))
    if height then
        local bonus = 0
        if lower:find('高码率', 1, true) then bonus = 3 end
        if lower:find('60', 1, true) then bonus = bonus + 1 end
        return height * 100 + bonus
    end
    if lower:find('8k', 1, true) then return 1000 end
    if lower:find('4k', 1, true) then return 900 end
    if lower:find('2k', 1, true) then return 800 end
    if lower:find('原画', 1, true) then return 700 end
    if lower:find('蓝光', 1, true) then return 600 end
    if lower:find('超清', 1, true) then return 500 end
    if lower:find('高清', 1, true) then return 400 end
    if lower:find('流畅', 1, true) then return 100 end
    return tonumber(format.height) or 0
end

local function bilibili_route_protocol(format)
    if source_kind == 'bilibili-live' then return live_route_protocol(format) end

    local protocol = tostring(format.protocol or ''):lower()
    local ext = tostring(format.ext or ''):lower()
    local id = tostring(format.format_id or ''):lower()
    if is_hls_route(format) then return 'HLS' end
    if protocol:find('flv', 1, true) or ext == 'flv' then return 'FLV' end
    if protocol:find('dash', 1, true) or id:find('dash', 1, true)
        or type(format.acodec) ~= 'string' or format.acodec == '' or format.acodec == 'none' then
        return 'DASH'
    end
    return protocol ~= '' and protocol:upper() or 'HTTP'
end

local function bilibili_codec_label(codec)
    return codec and LIVE_CODEC_LABELS[codec] or '未知编码'
end

-- Bilibili point-on-demand and live formats share this flat menu model. The
-- extractor inventory remains the source of truth; filters only decide which
-- already-discovered rows are visible.
local function bilibili_filter_rows(formats)
    local rows, codec_seen, quality_by_name = {}, {}, {}
    for _, format in ipairs(formats or {}) do
        if is_real_video(format) then
            local codec = normalize_live_codec(format.vcodec)
            local quality = bilibili_name(format)
            local protocol = bilibili_route_protocol(format)
            local row = {
                format = format,
                selector = format_selector(format),
                codec = codec,
                quality = quality,
                quality_rank = bilibili_quality_rank(format, quality),
                protocol = protocol,
                host = live_route_host(format),
            }
            table.insert(rows, row)
            if codec then codec_seen[codec] = true end
            local quality_entry = quality_by_name[quality]
            if not quality_entry or row.quality_rank > quality_entry.rank then
                quality_by_name[quality] = {name = quality, rank = row.quality_rank}
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.quality_rank ~= b.quality_rank then return a.quality_rank > b.quality_rank end
        if a.quality ~= b.quality then return a.quality < b.quality end
        local ac = a.codec and (LIVE_CODEC_RANK[a.codec] or math.huge) or math.huge
        local bc = b.codec and (LIVE_CODEC_RANK[b.codec] or math.huge) or math.huge
        if ac ~= bc then return ac < bc end
        if a.protocol ~= b.protocol then return a.protocol < b.protocol end
        return tostring(a.format.format_id or '') < tostring(b.format.format_id or '')
    end)

    local route_numbers = {}
    for _, row in ipairs(rows) do
        -- Route numbers are unique within a Bilibili quality tier.  Keeping
        -- the number independent of transport/codec makes the flat list easy
        -- to scan when no filter is selected (FLV/HLS/DASH are one inventory).
        local key = row.quality
        route_numbers[key] = (route_numbers[key] or 0) + 1
        row.route_number = route_numbers[key]
    end

    local codecs = {}
    for _, codec in ipairs(LIVE_CODEC_ORDER) do
        if codec_seen[codec] then table.insert(codecs, codec) end
    end
    local qualities = {}
    for _, entry in pairs(quality_by_name) do table.insert(qualities, entry) end
    table.sort(qualities, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.name < b.name
    end)
    return rows, codecs, qualities
end

local function primary_format_id(info)
    if type(info) ~= 'table' then return nil end
    if type(info.requested_formats) == 'table' then
        for _, format in ipairs(info.requested_formats) do
            local vcodec = tostring(format.vcodec or '')
            local id = format.format_id
            if id and vcodec ~= '' and vcodec ~= 'none' then return tostring(id) end
        end
    end
    local id = info.format_id
    if type(id) ~= 'string' or id == '' then return nil end
    -- A DASH selection is usually represented as video-id+audio-id.  The
    -- first selector is the video route shown in this menu.
    return id:match('^([^+/%[%s]+)') or id
end

local function current_bilibili_row(formats)
    local rows = bilibili_filter_rows(formats)
    local info = ytdl_info() or {}
    local actual_id = primary_format_id(info) or selected_actual_id
    if actual_id then
        for _, row in ipairs(rows) do
            if tostring(row.format.format_id) == tostring(actual_id) then return row end
        end
    end

    -- This fallback also covers media opened before ytdl_hook publishes its
    -- JSON.  It finds the decoded video route from mpv's real video params.
    local params = mp.get_property_native('video-params') or mp.get_property_native('video-out-params') or {}
    local codec = normalize_live_codec(info.vcodec) or normalize_live_codec(params.codec or params['codec-name'])
    local height = tonumber(info.height) or tonumber(params.h)
    local best = nil
    for _, row in ipairs(rows) do
        local row_height = tonumber(row.format.height) or tonumber(tostring(row.quality):match('(%d+)%s*[pP]'))
        if (not codec or row.codec == codec) and (not height or row_height == height) then
            if not best or row.quality_rank > best.quality_rank then best = row end
        end
    end
    return best
end

local function sync_bilibili_menu_state(formats)
    local row = current_bilibili_row(formats)
    if not row then return nil end
    selected_actual_id = tostring(row.format.format_id)
    filter_codec, filter_quality = row.codec, row.quality
    return row
end

local function filter_actions(kind, choices, active_value)
    local actions = {}
    for _, choice in ipairs(choices) do
        local value, label
        if type(choice) == 'table' then
            value = choice.value or choice.name
            label = choice.label or choice.name
        else
            value = choice
        end
        if not label then label = kind == 'codec' and codec_title(value) or tostring(value) end
        table.insert(actions, {
            name = 'filter-' .. kind .. ':' .. tostring(value),
            label = label,
            active = active_value == value,
        })
    end
    return actions
end

local function bilibili_filter_items(formats)
    local rows, codecs, qualities = bilibili_filter_rows(formats)
    if #rows == 0 then
        return {{title = '当前 Bilibili 媒体没有返回可选画质', selectable = false, muted = true, align = 'center'}}
    end

    local current = current_bilibili_row(formats)
    local highest = current or rows[1]
    local auto_title = '自动最高可用'
    if highest then
        auto_title = auto_title .. '：' .. bilibili_codec_label(highest.codec) .. ' ' .. highest.quality
    end

    local items = {{
        title = auto_title,
        value = '__auto__',
        active = selected_format_id == nil,
        separator = true,
        tooltip = '让 yt-dlp 从当前媒体实际返回的线路中选择最高可用项',
    }}

    if #codecs > 0 then
        table.insert(items, {
            title = '编码', value = '__filter-codec__', keep_open = true,
            actions = filter_actions('codec', codecs, filter_codec),
            actions_text = true, actions_always_visible = true,
        })
    end

    if #qualities > 0 then
        table.insert(items, {
            title = '画质', value = '__filter-quality__', keep_open = true,
            actions = filter_actions('quality', qualities, filter_quality),
            actions_text = true, actions_always_visible = true,
            separator = true,
        })
    end

    local matching_count = 0
    for _, row in ipairs(rows) do
        if (not filter_codec or row.codec == filter_codec)
            and (not filter_quality or row.quality == filter_quality) then
            matching_count = matching_count + 1
            local title = table.concat({row.protocol, row.quality, '线路 ' .. tostring(row.route_number)}, ' · ')
            table.insert(items, {
                title = title,
                hint = (not filter_codec) and bilibili_codec_label(row.codec) or nil,
                value = row.selector,
                active = live_format_is_active(row.format),
                tooltip = 'CDN：' .. row.host .. '\n格式：' .. tostring(row.format.format_id or ''),
            })
        end
    end

    if matching_count == 0 then
        table.insert(items, {
            title = '没有符合当前编码与画质条件的线路',
            selectable = false, muted = true, align = 'center',
        })
    end
    return items
end

local function menu_data(items)
    return {
        type = 'web-quality',
        title = title_for_kind(source_kind),
        search_style = 'disabled',
        callback = { 'bilibili_live_quality', 'menu-event' },
        items = items,
    }
end

local function update_menu(items)
    mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(menu_data(items)))
end

local function loading_items()
    return {{ title = '正在读取当前网页媒体可选画质…', selectable = false, muted = true, align = 'center' }}
end

local function failed_items(message)
    return {{ title = message, selectable = false, muted = true, align = 'center' }}
end

local function query_failure_message(detail)
    detail = tostring(detail or '')
    if source_kind == 'bilibili-live' and detail:lower():find('streamer is not live', 1, true) then
        return '当前 Bilibili 直播已下播，暂无可选画质'
    end
    return '读取当前网页媒体画质失败'
end

local function formats_to_items(formats)
    if source_kind == 'bilibili-video' or source_kind == 'bilibili-live' then
        return bilibili_filter_items(formats)
    end

    local rows, counts = {}, {}
    for _, format in ipairs(formats or {}) do
        if is_real_video(format) then
            local name = source_kind:match('bilibili') and bilibili_name(format) or youtube_name(format)
            counts[name] = (counts[name] or 0) + 1
            table.insert(rows, { id = format.format_id, selector = format_selector(format), name = name, format = format })
        end
    end
    table.sort(rows, function(a, b)
        if source_kind == 'bilibili-live' then
            local at, bt = bilibili_live_tier(a.format), bilibili_live_tier(b.format)
            if at ~= bt then return at > bt end
        end
        local ap, bp = tonumber(a.format.preference) or 0, tonumber(b.format.preference) or 0
        if ap ~= bp then return ap > bp end
        local ah, bh = tonumber(a.format.height) or 0, tonumber(b.format.height) or 0
        if ah ~= bh then return ah > bh end
        local af, bf = tonumber(a.format.fps) or 0, tonumber(b.format.fps) or 0
        if af ~= bf then return af > bf end
        return a.id < b.id
    end)

    if #rows == 0 then return failed_items('当前网页媒体没有返回可选画质') end
    local items = {{
        title = '自动：最高可用', value = '__auto__', active = selected_format_id == nil,
        tooltip = '让 yt-dlp 从当前媒体实际返回的线路中选择最高可用项',
    }}
    local ordinal = {}
    for _, row in ipairs(rows) do
        local title = row.name
        local duplicate = counts[row.name] > 1
        if duplicate then ordinal[row.name] = (ordinal[row.name] or 0) + 1 end
        local detail = detail_for(row.format, source_kind, duplicate and ordinal[row.name] or nil)
        if #detail > 0 then title = title .. ' · ' .. table.concat(detail, ' · ') end
        table.insert(items, {
            title = title, value = row.selector,
            active = selected_actual_id and selected_actual_id == row.id or (not selected_actual_id and selected_selector == row.selector),
            tooltip = '当前媒体由 yt-dlp 实际返回的可选格式',
        })
    end
    return items
end

local function playlist_index_by_id(id)
    if id == nil then return nil end
    for index, entry in ipairs(mp.get_property_native('playlist') or {}) do
        if tostring(entry.id) == tostring(id) then return index - 1 end
    end
end

local function abandon_pending_playlist_swap(message)
    local swap = pending_playlist_swap
    pending_playlist_swap = nil
    if not swap then return end
    local appended_index = playlist_index_by_id(swap.appended_entry_id)
    if appended_index then pcall(mp.commandv, 'playlist-remove', tostring(appended_index)) end
    if message then mp.msg.warn('[web_quality] ' .. message) end
end

local function wait_for_appended_entry(swap)
    if pending_playlist_swap ~= swap or swap.token ~= reload_token then return end
    local playlist = mp.get_property_native('playlist') or {}
    if #playlist >= swap.old_count + 1 then
        local appended = playlist[swap.old_count + 1]
        if appended and appended.id ~= nil then
            swap.appended_entry_id = appended.id
            swap.play_started = true
            mp.commandv('playlist-play-index', tostring(swap.old_count))
            return
        end
    end
    if mp.get_time() >= swap.deadline then
        abandon_pending_playlist_swap('追加切换地址超时，已保留原直播')
        return
    end
    mp.add_timeout(0.05, function() wait_for_appended_entry(swap) end)
end

local function replace_current_entry_with_url(url)
    local old_position = mp.get_property_number('playlist-pos', -1)
    local old_count = mp.get_property_number('playlist-count', 0)
    if old_position < 0 or old_count <= 0 then
        mp.commandv('loadfile', url, 'replace')
        return
    end

    -- Append the selected page or signed live route, explicitly play that new
    -- index, then move/remove it back to the original playlist position.
    pending_playlist_swap = {
        old_position = old_position,
        old_count = old_count,
        token = reload_token,
        old_entry_id = (mp.get_property_native('playlist') or {})[old_position + 1]
            and (mp.get_property_native('playlist') or {})[old_position + 1].id or nil,
        deadline = mp.get_time() + 5,
    }
    mp.commandv('loadfile', url, 'append')
    wait_for_appended_entry(pending_playlist_swap)
end

local function prepare_direct_live_route(route)
    mp.commandv('script-message-to', 'web_source_context', 'prepare-direct-reload', utils.format_json({
        url = source_url,
        kind = source_kind,
        stream_url = route.url,
    }))
end

local function restore_playlist_after_reload()
    local swap = pending_playlist_swap
    if not swap then return end
    if swap.token ~= reload_token then return end
    if not swap.play_started or not swap.appended_entry_id then return end
    local current_position = mp.get_property_number('playlist-pos', -1)
    local current_entry = (mp.get_property_native('playlist') or {})[current_position + 1]
    if not current_entry or tostring(current_entry.id) ~= tostring(swap.appended_entry_id) then return end

    local new_position = playlist_index_by_id(swap.appended_entry_id)
    local old_position = playlist_index_by_id(swap.old_entry_id)
    if new_position == nil or old_position == nil then
        abandon_pending_playlist_swap('无法恢复直播画质切换后的播放列表位置')
        return
    end
    pending_playlist_swap = nil
    mp.commandv('playlist-move', tostring(new_position), tostring(old_position))
    mp.add_timeout(0, function()
        local stale_position = playlist_index_by_id(swap.old_entry_id)
        if stale_position ~= nil then pcall(mp.commandv, 'playlist-remove', tostring(stale_position)) end
    end)
end

local function reload_with_selector(selector, automatic_route, automatic_protocol)
    if not source_url then
        mp.osd_message('当前不是 Bilibili 或 YouTube 网页媒体', 2)
        return
    end
    local direct_route = nil
    if source_kind == 'bilibili-live' then
        direct_route = automatic_route or (selector == '__auto__' and live_auto_format() or live_format_for_selector(selector))
    end

    selected_selector = selector == '__auto__' and nil or selector
    selected_format_id = selected_selector
    selected_actual_id = direct_route and tostring(direct_route.format_id) or nil
    expected_selector = direct_route and nil or selected_selector
    pending_reload_url, reload_start_seen = source_url, false
    reload_uses_direct_route = direct_route ~= nil
    reload_token = reload_token + 1
    local token = reload_token
    -- `best` usually means the best pre-muxed stream.  It is frequently a
    -- lower tier than the actual highest separate video+audio pair. Bilibili
    -- live is the exception: every live route is already muxed despite some
    -- extractor responses leaving `acodec` blank.
    if direct_route then
        -- Bilibili live format IDs contain a request-specific route signature.
        -- Reopening the webpage with that old ID fails, while this freshly
        -- queried signed stream URL is immediately playable.
        restore_ytdl_format = nil
        prepare_direct_live_route(direct_route)
        if automatic_protocol == 'HLS' then
            mp.osd_message('检测到直播时移，正在切换 HLS', 2)
        elseif automatic_protocol == 'FLV' then
            mp.osd_message('HLS 不支持直播回看，正在切换 FLV', 2)
        else
            mp.osd_message(selected_selector and '正在切换直播线路' or '正在切换为最高可用线路', 2)
        end
        replace_current_entry_with_url(direct_route.url)
    else
        restore_ytdl_format = mp.get_property('ytdl-format') or ''
        local automatic_selector = AUTO_SELECTOR
        local applied_selector = selected_selector or automatic_selector
        if selected_selector then expected_selector = selected_selector end
        mp.set_property('ytdl-format', applied_selector)
        mp.osd_message(selected_selector and '正在切换网页画质' or '正在切换为最高可用画质', 2)
        replace_current_entry_with_url(source_url)
    end
    mp.add_timeout(35, function()
        if token == reload_token and (restore_ytdl_format ~= nil or reload_uses_direct_route) then
            if restore_ytdl_format ~= nil then mp.set_property('ytdl-format', restore_ytdl_format) end
            abandon_pending_playlist_swap()
            restore_ytdl_format, pending_reload_url, selected_format_id, selected_selector, selected_actual_id, expected_selector, reload_uses_direct_route = nil, nil, nil, nil, nil, nil, false
            mp.osd_message('线路切换超时，已保留原直播', 3)
        end
    end)
end

local function automatic_dvr_key()
    if not source_url or source_url == '' then return nil end
    return source_url .. '\31' .. tostring(source_entry_id or '')
end

local function hls_dvr_window(manifest)
    if type(manifest) ~= 'string' or not manifest:find('#EXTM3U', 1, true) then return nil end

    local seconds = 0
    for value in manifest:gmatch('#EXTINF:([%d%.]+)') do
        seconds = seconds + (tonumber(value) or 0)
    end
    for value in manifest:gmatch('#EXT%-X%-PART:[^\r\n]-DURATION=([%d%.]+)') do
        seconds = seconds + (tonumber(value) or 0)
    end

    local event_playlist = manifest:find('#EXT%-X%-PLAYLIST%-TYPE:%s*EVENT')
        or manifest:find('#EXT%-X%-PLAYLIST%-TYPE:%s*VOD')
    local has_program_time = manifest:find('#EXT%-X%-PROGRAM%-DATE%-TIME:') ~= nil
    if seconds >= AUTO_DVR_MINIMUM_WINDOW and (event_playlist or has_program_time) then return seconds end
end

local function probe_hls_dvr_route(route, fallback_route, key)
    local args = {
        'curl.exe', '--fail', '--silent', '--show-error', '--location',
        '--connect-timeout', '5', '--max-time', '10',
        '--user-agent', 'Mozilla/5.0', '--referer', 'https://live.bilibili.com/',
        '--', route.url,
    }
    auto_dvr_probe_abort = mp.command_native_async({
        name = 'subprocess', args = args, playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(success, result, error)
        auto_dvr_probe_abort = nil
        if key ~= automatic_dvr_key() or selected_format_id ~= nil then return end
        local current_transport = current_live_transport()
        if not success or not result or result.status ~= 0 then
            mp.msg.verbose('[web_quality] HLS DVR probe failed: ' .. tostring(error or (result and result.stderr) or 'unknown error'))
            if current_transport == 'HLS' and fallback_route then
                reload_with_selector('__auto__', fallback_route, 'FLV')
            end
            return
        end

        local window = hls_dvr_window(result.stdout or '')
        if not window then
            mp.msg.verbose('[web_quality] HLS route has no extended DVR window; keeping FLV')
            if current_transport == 'HLS' and fallback_route then
                reload_with_selector('__auto__', fallback_route, 'FLV')
            end
            return
        end

        mp.msg.info(string.format('[web_quality] HLS DVR window detected: %.0fs', window))
        if current_transport ~= 'HLS' then reload_with_selector('__auto__', route, 'HLS') end
    end)
end

local function maybe_select_bilibili_dvr_hls()
    if source_kind ~= 'bilibili-live' or selected_format_id ~= nil then return end

    local key = automatic_dvr_key()
    if not key or auto_dvr_probe_key == key then return end
    auto_dvr_probe_key = key

    local url = source_url
    local args = {
        bridge, '--no-playlist', '--no-warnings', '--no-progress',
        '--socket-timeout', '12', '--extractor-retries', '1', '--dump-single-json',
    }
    proxy_args(args)
    table.insert(args, url)
    auto_dvr_probe_abort = mp.command_native_async({
        name = 'subprocess', args = args, playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(success, result, error)
        auto_dvr_probe_abort = nil
        if key ~= automatic_dvr_key() or current_live_transport() == 'HLS' or selected_format_id ~= nil then return end
        if not success or not result or result.status ~= 0 then
            mp.msg.verbose('[web_quality] Bilibili DVR format probe failed: ' .. tostring(error or (result and result.stderr) or 'unknown error'))
            return
        end

        local data = utils.parse_json(result.stdout or '')
        if type(data) ~= 'table' or type(data.formats) ~= 'table' then return end
        local route = live_auto_hls_format(data.formats)
        local fallback_route = live_auto_flv_format(data.formats)
        if route then
            probe_hls_dvr_route(route, fallback_route, key)
        elseif current_live_transport() == 'HLS' and fallback_route then
            reload_with_selector('__auto__', fallback_route, 'FLV')
        end
    end)
end

local function fetch_formats()
    if not source_url then
        update_menu(failed_items('当前不是 Bilibili 或 YouTube 网页媒体'))
        return
    end
    if query_abort then query_abort() end
    if query_timeout then query_timeout:kill(); query_timeout = nil end
    query_serial = query_serial + 1
    local serial = query_serial
    local generation, url = source_generation, source_url
    -- This command only powers the menu.  A slow YouTube challenge or a bad
    -- network route must never leave the uosc menu waiting forever.
    local args = {
        bridge, '--no-playlist', '--no-warnings', '--no-progress',
        '--socket-timeout', '12', '--extractor-retries', '1', '--dump-single-json',
    }
    proxy_args(args)
    table.insert(args, url)
    query_abort = mp.command_native_async({
        name = 'subprocess', args = args, playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(success, result, error)
        if serial ~= query_serial then return end
        query_abort = nil
        if query_timeout then query_timeout:kill(); query_timeout = nil end
        if generation ~= source_generation or url ~= source_url then return end
        if not success or not result or result.status ~= 0 then
            local detail = error or (result and (result.stderr or result.error_string)) or 'unknown error'
            mp.msg.warn('[web_quality] format query failed: ' .. tostring(detail))
            update_menu(failed_items(query_failure_message(detail)))
            return
        end
        local data = utils.parse_json(result.stdout or '')
        if type(data) ~= 'table' or type(data.formats) ~= 'table' then
            update_menu(failed_items('网页媒体画质数据格式无效'))
            return
        end
        latest_formats = data.formats
        if source_kind == 'youtube-video' and (data.live_status == 'is_live' or data.is_live) then
            source_kind = 'youtube-live'
            mp.set_property('user-data/web_quality/kind', source_kind)
        end
        if source_kind == 'bilibili-video' or source_kind == 'bilibili-live' then
            sync_bilibili_menu_state(latest_formats)
        end
        update_menu(formats_to_items(latest_formats))
    end)
    query_timeout = mp.add_timeout(25, function()
        if serial ~= query_serial or not query_abort then return end
        -- Invalidate the asynchronous callback before aborting it.  Some mpv
        -- builds still invoke the subprocess callback after cancellation.
        query_serial = query_serial + 1
        query_abort()
        query_abort = nil
        query_timeout = nil
        update_menu(failed_items('读取网页媒体画质超时，请稍后重试'))
    end)
end

local function open_menu()
    if not source_url then
        mp.osd_message('当前不是 Bilibili 或 YouTube 网页媒体', 2)
        return
    end
    -- A menu opening is a fresh view of the actual playing route.  Filters
    -- from an earlier visit must not mask it while the format query completes.
    if source_kind == 'bilibili-video' or source_kind == 'bilibili-live' then
        filter_codec, filter_quality = nil, nil
    end
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu_data(loading_items())))
    fetch_formats()
end

local function menu_event(json)
    local event = utils.parse_json(json or '')
    if type(event) ~= 'table' or event.type ~= 'activate' then return end
    local action = type(event.action) == 'string' and event.action or nil
    local codec = action and action:match('^filter%-codec:(.+)$')
    if codec then
        if filter_codec == codec then filter_codec = nil else filter_codec = codec end
        if latest_formats then update_menu(formats_to_items(latest_formats)) end
        return
    end
    local quality = action and action:match('^filter%-quality:(.+)$')
    if quality then
        if filter_quality == quality then filter_quality = nil else filter_quality = quality end
        if latest_formats then update_menu(formats_to_items(latest_formats)) end
        return
    end
    if type(event.value) ~= 'string' or event.value:match('^__filter%-') then return end
    reload_with_selector(event.value)
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'web-quality')
end

mp.add_key_binding(nil, 'open-menu', open_menu)
mp.register_script_message('menu-event', menu_event)

mp.register_event('start-file', remember_source)
mp.register_event('file-loaded', function()
    -- The shared context also refreshes here from yt-dlp's webpage_url when
    -- an extractor replaces every visible playback URL.
    remember_source()
    if source_kind == 'youtube-video' and youtube_is_live() then
        source_kind = 'youtube-live'
        mp.set_property('user-data/web_quality/kind', source_kind)
    end
    if restore_ytdl_format ~= nil then
        mp.set_property('ytdl-format', restore_ytdl_format)
        restore_ytdl_format = nil
    end
    -- The ytdl hook publishes the resolved extractor JSON.  Use it as the
    -- source of truth after a requested live route has reloaded: this prevents
    -- a failed selector from remaining falsely highlighted in the menu.
    if selected_selector and not reload_uses_direct_route then
        local info = ytdl_info()
        local actual_id = info and info.format_id
        if type(actual_id) == 'string' and actual_id ~= '' then
            selected_actual_id = actual_id
            local expected_id = selected_selector:match('^([^+/%[]+)')
            if expected_id and actual_id ~= expected_id then
                mp.osd_message('所选线路不可用，已回退到实际可播放线路', 3)
                mp.msg.warn(string.format('[web_quality] requested %s, resolved %s', expected_id, actual_id))
            end
        end
    end
    restore_playlist_after_reload()
    pending_reload_url = nil
    reload_start_seen = false
    reload_uses_direct_route = false
    maybe_select_bilibili_dvr_hls()
end)
mp.register_event('end-file', function()
    if query_abort then query_abort(); query_abort = nil end
    if query_timeout then query_timeout:kill(); query_timeout = nil end
    if reload_start_seen and (restore_ytdl_format ~= nil or reload_uses_direct_route) then
        if restore_ytdl_format ~= nil then mp.set_property('ytdl-format', restore_ytdl_format) end
        abandon_pending_playlist_swap()
        restore_ytdl_format, pending_reload_url, selected_format_id, selected_selector, selected_actual_id, expected_selector, reload_uses_direct_route = nil, nil, nil, nil, nil, nil, false
    end
    reload_start_seen = false
    -- `end-file` is also emitted while yt-dlp is reopening the same stream.
    -- Do not clear here: the durable source must survive that gap.  The
    -- idle-active observer below handles actual Stop/idle transitions.
end)
mp.register_event('shutdown', function()
    if query_abort then query_abort() end
    if query_timeout then query_timeout:kill() end
    abandon_pending_playlist_swap()
    clear_source()
end)

mp.observe_property('user-data/web_source/context', 'native', function()
    remember_source()
end)

remember_source()
