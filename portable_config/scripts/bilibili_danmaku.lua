local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'

local temp_dir = os.getenv('TEMP') or os.getenv('TMP')
    or mp.command_native({ 'expand-path', '~~/_cache' })
local converter = mp.command_native({ 'expand-path', '~~/tools/danmaku2ass.py' })
local vod_pipeline = mp.command_native({ 'expand-path', '~~/tools/bilibili_danmaku_pipeline.py' })
local live_receiver = mp.command_native({ 'expand-path', '~~/tools/bilibili_live_danmaku.py' })
local live_sender = mp.command_native({ 'expand-path', '~~/tools/bilibili_live_send.py' })
local bridge = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/publish_v13/mpv-cookie-bridge.exe' })
local bilibili_fetcher = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/bilibili_cookie_fetch.py' })
local python = mp.command_native({ 'expand-path', '~~/../python.exe' })
local pythonw = mp.command_native({ 'expand-path', '~~/../pythonw.exe' })
local live_python = utils.file_info(pythonw) and pythonw or python
local BILIBILI_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36'

local request_id = 0
local loading = false
local loading_source_path = nil
local active = nil
local pending = {}
local live_state = nil
local live_poll_timer = nil
local temporary_serial = 0
-- yt-dlp replaces mpv's `path` with the resolved HLS/FLV URL after it opens a
-- Bilibili page.  Keep the original playlist URL for the lifetime of the
-- current media item so the danmaku controls still know which site/room was
-- opened after that replacement.
local source_context = nil
local source_generation = 0
-- A Ctrl+F5 reload can temporarily expose only the resolved HLS URL.  Keep
-- the original room identity long enough to carry the live receiver through
-- that reload.
local live_refresh_context = nil

-- Intentionally session-only.  No script option or cache is used to restore
-- these switches after mpv restarts.
local enabled = { normal = false, superchat = false }

-- Live messages are deliberately rendered by this script instead of passing
-- through uosc.  The receiver was healthy, but the extra script-message →
-- uosc overlay hop made a successful live connection look like a failure when
-- the UI overlay did not repaint.
local live_overlay = mp.create_osd_overlay('ass-events')
live_overlay.z = 1500 -- Keep uosc menus and controls above danmaku.
local vod_overlay = mp.create_osd_overlay('ass-events')
vod_overlay.z = 1500 -- Keep uosc menus and controls above danmaku.
local render_timer = nil
local update_render_timer = nil
local render_timer_fps = 0
local live_close_binding_active = false
local live_close_target = nil
local live_close_binding_name = 'bilibili_danmaku-live-superchat-close'
local update_open_menu = nil
local live_send_in_progress = false
local queue_live_normal = nil
local renderer_instance = string.format('%d-%d', os.time(), math.random(1, 1000000000))
local heartbeat_timer = nil
local font_scale_step = 0.1
local font_scale_min = 0.5
local font_scale_max = 2
-- Runtime-adjustable Bilibili-web-style danmaku display settings.
local DANMAKU_FONT = 'SimHei' -- 黑体, like Bilibili web danmaku.
local area_min, area_max = 25, 100
local opacity_min, opacity_max = 20, 100
-- 参数默认值。启动时读取 mpv 现有弹幕配置（script-opts 中
-- bilibili_danmaku-opacity / -area / -font-size，百分比）作为初始值，
-- 而不是硬编码 100。菜单调整一律为“绝对设置”，不会基于当前值再次乘算。
local opts = { opacity = 100, area = 100, font_size = 100 }
options.read_options(opts, 'bilibili_danmaku')
local render_area = math.max(area_min, math.min(area_max, math.floor(opts.area + 0.5)))
local render_opacity = math.max(opacity_min, math.min(opacity_max, math.floor(opts.opacity + 0.5)))
local font_scale = math.floor(
    math.max(font_scale_min * 100, math.min(font_scale_max * 100, opts.font_size)) + 0.5) / 100
local opacity_step = 5

-- 参数持久化：调整后写回状态文件，下次启动时读取恢复。
-- 注意：本 mpv 构建中 mp.get_script_directory() 可能返回 nil，故改用健壮回退，
-- 避免脚本加载时崩溃（崩溃会导致弹幕按钮不显示）。
local function home_dir()
    return os.getenv('APPDATA') or os.getenv('HOME') or os.getenv('USERPROFILE') or nil
end

local persist_path
do
    local d = mp.get_script_directory()
    if d and d ~= '' then
        persist_path = d .. '/bilibili_danmaku_state.conf'
    else
        local base = home_dir()
        if base then persist_path = base .. '/bilibili_danmaku_state.conf' end
    end
end

local function load_persisted()
    if not persist_path then return end
    local f = io.open(persist_path, 'r')
    if not f then return end
    for line in f:lines() do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*([%d%.]+)')
        if k and v then
            local num = tonumber(v)
            if num then
                if k == 'opacity' then
                    render_opacity = math.max(opacity_min, math.min(opacity_max, math.floor(num + 0.5)))
                elseif k == 'font' then
                    font_scale = math.max(font_scale_min, math.min(font_scale_max, num))
                end
            end
        end
    end
    f:close()
end

local function save_persisted()
    if not persist_path then return end
    local f = io.open(persist_path, 'w')
    if not f then return end
    f:write('opacity=' .. tostring(math.floor(render_opacity + 0.5)) .. '\n')
    f:write('font=' .. tostring(font_scale) .. '\n')
    f:close()
end

load_persisted()

local function publish_renderer_heartbeat()
    mp.set_property_native('user-data/bilibili_danmaku/heartbeat', {
        instance = renderer_instance,
        name = mp.get_script_name(),
        updated_at = mp.get_time(),
    })
    mp.set_property_native('user-data/bilibili_danmaku/renderer-info', {
        instance = renderer_instance,
        name = mp.get_script_name(),
        version = 2,
    })
end

publish_renderer_heartbeat()
heartbeat_timer = mp.add_periodic_timer(0.5, publish_renderer_heartbeat)

local function ass_escape(value)
    return tostring(value or ''):gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}')
        :gsub('[\r\n]+', ' ')
end

local function color_to_ass(color)
    if type(color) == 'number' then
        local red = math.floor(color / 65536) % 256
        local green = math.floor(color / 256) % 256
        local blue = color % 256
        return string.format('%02X%02X%02X', blue, green, red), red, green, blue
    end
    local hex = tostring(color or ''):gsub('#', '')
    if #hex == 6 and hex:match('^[%x]+$') then
        local red = tonumber(hex:sub(1, 2), 16) or 42
        local green = tonumber(hex:sub(3, 4), 16) or 96
        local blue = tonumber(hex:sub(5, 6), 16) or 178
        return string.format('%02X%02X%02X', blue, green, red), red, green, blue
    end
    return 'FFFFFF', 255, 255, 255
end

local function utf8_length_at(value, index)
    local byte = value:byte(index) or 0
    if byte < 0x80 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

local function estimate_text_width(value, font_size)
    local width, index = 0, 1
    value = tostring(value or '')
    while index <= #value do
        local byte = value:byte(index) or 0
        width = width + (byte < 0x80 and font_size * 0.55 or font_size)
        index = index + utf8_length_at(value, index)
    end
    return width
end

local function truncate_text(value, max_width, font_size)
    value = tostring(value or ''):gsub('[\r\n]+', ' ')
    if estimate_text_width(value, font_size) <= max_width then return ass_escape(value) end
    local output, index = {}, 1
    local suffix_width = estimate_text_width('…', font_size)
    local used = 0
    while index <= #value do
        local length = utf8_length_at(value, index)
        local byte = value:byte(index) or 0
        local next_width = byte < 0x80 and font_size * 0.55 or font_size
        if used + next_width + suffix_width > max_width then break end
        output[#output + 1] = value:sub(index, index + length - 1)
        used = used + next_width
        index = index + length
    end
    return ass_escape(table.concat(output) .. '…')
end

local function wrap_text(value, max_width, font_size)
    value = tostring(value or ''):gsub('[\r\n]+', ' ')
    local lines, line, used, index = {}, {}, 0, 1
    while index <= #value do
        local length = utf8_length_at(value, index)
        local byte = value:byte(index) or 0
        local char = value:sub(index, index + length - 1)
        local char_width = byte < 0x80 and font_size * 0.55 or font_size
        if #line > 0 and used + char_width > max_width then
            lines[#lines + 1] = table.concat(line)
            line, used = {}, 0
        end
        line[#line + 1] = char
        used = used + char_width
        index = index + length
    end
    if #line > 0 then lines[#lines + 1] = table.concat(line) end
    if #lines == 0 then lines[1] = '' end
    return lines
end

local function format_superchat_price(value)
    local price = tonumber(value)
    if not price then return '?' end
    if price == math.floor(price) then return tostring(math.floor(price)) end
    return string.format('%.1f', price):gsub('%.0$', '')
end

local function live_font_size(height)
    local size = math.max(19, math.floor(50 * height / 1080 + 0.5) - 1)
    if mp.get_property_bool('fullscreen', false) then
        size = math.max(19, math.floor(size * 0.80 + 0.5))
    end
    return math.max(1, math.floor(size * font_scale + 0.5))
end

local function normalized_live_text(value)
    return tostring(value or ''):gsub('[\r\n]+', ' ')
end

local function prune_pending_self_messages(state, now)
    local entries = state.pending_self_messages or {}
    for index = #entries, 1, -1 do
        if entries[index].expires_at <= now then table.remove(entries, index) end
    end
end

local function track_pending_self_message(state, request_id, text)
    if not state then return nil end
    local now = mp.get_time()
    prune_pending_self_messages(state, now)
    local entry = {
        request_id = request_id,
        text = normalized_live_text(text),
        expires_at = now + 15,
        received = false,
        echoed = false,
    }
    state.pending_self_messages = state.pending_self_messages or {}
    state.pending_self_messages[#state.pending_self_messages + 1] = entry
    return entry
end

local function remove_pending_self_message(state, entry)
    if not state or not entry then return end
    for index = #(state.pending_self_messages or {}), 1, -1 do
        if state.pending_self_messages[index] == entry then
            table.remove(state.pending_self_messages, index)
            return
        end
    end
end

local function find_pending_self_message(state, text)
    if not state then return nil end
    prune_pending_self_messages(state, mp.get_time())
    text = normalized_live_text(text)
    for _, entry in ipairs(state.pending_self_messages or {}) do
        if entry.text == text then return entry end
    end
end

local function clear_live_close_binding()
    if live_close_binding_active then mp.remove_key_binding(live_close_binding_name) end
    live_close_binding_active, live_close_target = false, nil
end

local function update_live_status()
    local state = live_state
    if not state then
        mp.set_property_native('user-data/bilibili_danmaku/live-status', {
            active = false, connected = false, received_normal = 0, rendered_normal = 0,
        })
        return
    end
    mp.set_property_native('user-data/bilibili_danmaku/live-status', {
        active = true,
        connected = state.ready == true,
        room_id = state.room_id,
        received_normal = state.received_normal or 0,
        rendered_normal = state.rendered_normal or 0,
        received_superchat = state.received_superchat or 0,
        rendered_superchat = state.rendered_superchat or 0,
        last_error = state.last_error or '',
    })
end

local function prune_live_items(state, now)
    for index = #(state.normal or {}), 1, -1 do
        if state.normal[index].expires_at <= now then table.remove(state.normal, index) end
    end
    for index = #(state.cards or {}), 1, -1 do
        if state.cards[index].expires_at <= now then table.remove(state.cards, index) end
    end
end

local function refresh_live_close_target()
    local state = live_state
    local mouse = mp.get_property_native('mouse-pos') or {}
    local hovered = nil
    if state and type(mouse.x) == 'number' and type(mouse.y) == 'number' then
        for _, card in ipairs(state.cards or {}) do
            local zone = card.close_zone
            if zone and mouse.x >= zone.ax and mouse.x <= zone.bx and mouse.y >= zone.ay and mouse.y <= zone.by then
                hovered = card
                break
            end
        end
    end
    if hovered then
        live_close_target = hovered.id
        if not live_close_binding_active then
            mp.add_forced_key_binding('MBTN_LEFT', live_close_binding_name, function()
                local current = live_state
                if not current or not live_close_target then return end
                for index = #(current.cards or {}), 1, -1 do
                    if current.cards[index].id == live_close_target then
                        table.remove(current.cards, index)
                        break
                    end
                end
                clear_live_close_binding()
            end)
            live_close_binding_active = true
        end
    else
        clear_live_close_binding()
    end
end

local function render_live_overlay()
    local state = live_state
    if not state then
        clear_live_close_binding()
        live_overlay:remove()
        return
    end

    local width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then return end
    local now = mp.get_time()
    prune_live_items(state, now)
    if #(state.normal or {}) == 0 and #(state.cards or {}) == 0 then
        clear_live_close_binding()
        live_overlay:remove()
        return
    end

    local events = {}
    local font_size = live_font_size(height)
    local line_height = math.max(font_size * 1.2, 1)
    -- 显示区域跟随 render_area；默认 100% = 铺满整屏高度。
    local area_frac = math.max(area_min, math.min(area_max, render_area)) / 100
    local lane_count = math.max(1, math.floor((height * area_frac) / line_height))
    for _, message in ipairs(state.normal or {}) do
        local progress = math.max(0, math.min(1, (now - message.started_at) / message.duration))
        local message_width = math.max(1, estimate_text_width(message.text, font_size))
        local x = width - (width + message_width) * progress
        local y = font_size * 0.75 + (message.lane - 1) * line_height
        if message.lane <= lane_count then
            local is_self = message.is_self == true
            local color = is_self and 'FFE500' or message.color
            -- 细描边, proportional to the scaled live font.
            local border_color = is_self and '4D3100' or '000000'
            local border = is_self and math.max(1.5, font_size * 0.05) or math.max(1.5, font_size * 0.04)
            local opacity_frac = math.max(0, math.min(1, render_opacity / 100))
            -- 不透明度 100% = 完全不透明(alpha 0)；20% = 高透明(alpha 约 204)。
            -- 自己发的弹幕用更醒目的黄色及更强描边，颜色已足够区分，透明度只由不透明度控制。
            local alpha = string.format('%02X', math.max(0, math.min(255, math.floor((1 - opacity_frac) * 255 + 0.5))))
            events[#events + 1] = string.format(
                '{\\an4\\pos(%.1f,%.1f)\\fn%s\\fs%d\\b1\\bord%.1f\\3c&H%s&\\1c&H%s&\\alpha&H%s&}%s',
                x, y, DANMAKU_FONT, font_size, border, border_color, color, alpha, ass_escape(message.text)
            )
        end
    end

    local scale = math.max(0.75, height / 1080)
    local margin = math.floor(12 * scale + 0.5)
    local card_width = math.min(math.floor(width * 0.42 + 0.5), math.max(math.floor(280 * scale + 0.5), math.floor(width * 0.22 + 0.5)))
    local card_min_height = math.floor(76 * scale + 0.5)
    local card_font = math.max(24, math.floor(26 * scale + 0.5))
    local user_font = math.max(14, math.floor(16 * scale + 0.5))
    local card_gap = math.floor(8 * scale + 0.5)
    local text_top = math.floor(40 * scale + 0.5)
    local text_line_height = math.ceil(card_font * 1.2)
    local text_bottom_padding = math.floor(10 * scale + 0.5)
    local top_bar_bottom = mp.get_property_number('user-data/uosc/top-bar-bottom', 0) or 0
    local y = math.max(margin, math.floor(top_bar_bottom + margin + 0.5))
    local max_y = height - margin
    for _, card in ipairs(state.cards or {}) do
        local text_lines = wrap_text(card.text, card_width - math.floor(24 * scale + 0.5), card_font)
        local card_height = math.max(card_min_height, text_top + #text_lines * text_line_height + text_bottom_padding)
        if y + card_height > max_y then break end
        local ax, bx = margin, margin + card_width
        local by = y + card_height
        local background, red, green, blue = color_to_ass(card.color)
        local brightness = red * 0.299 + green * 0.587 + blue * 0.114
        local foreground = brightness > 155 and '000000' or 'FFFFFF'
        events[#events + 1] = string.format(
            '{\\an7\\pos(%d,%d)\\1c&H%s&\\alpha&H14&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}',
            ax, y, background, card_width, card_width, card_height, card_height
        )
        local close_size = math.max(32, math.floor(40 * scale + 0.5))
        local close_ax, close_ay = bx - close_size - math.floor(8 * scale + 0.5), y + math.floor(7 * scale + 0.5)
        card.close_zone = {ax = close_ax, ay = close_ay, bx = close_ax + close_size, by = close_ay + close_size}
        events[#events + 1] = string.format('{\\an7\\pos(%d,%d)\\fnMicrosoft YaHei\\fs%d\\bord0\\1c&H%s&}×', close_ax, close_ay, close_size, foreground)
        local remaining_seconds = math.max(0, math.ceil(card.expires_at - now))
        local details = string.format('  %s￥  %ds', format_superchat_price(card.price), remaining_seconds)
        local header_width = card_width - close_size - math.floor(34 * scale + 0.5)
        local user_width = math.max(user_font * 2, header_width - estimate_text_width(details, user_font))
        events[#events + 1] = string.format(
            '{\\an7\\pos(%d,%d)\\fnMicrosoft YaHei\\fs%d\\b1\\bord0\\1c&H%s&}%s',
            ax + math.floor(12 * scale + 0.5), y + math.floor(10 * scale + 0.5), user_font, foreground,
            truncate_text(card.user, user_width, user_font) .. ass_escape(details)
        )
        for line_index, line in ipairs(text_lines) do
            events[#events + 1] = string.format(
                '{\\an7\\pos(%d,%d)\\fnMicrosoft YaHei\\fs%d\\bord0\\1c&H%s&}%s',
                ax + math.floor(12 * scale + 0.5), y + text_top + (line_index - 1) * text_line_height,
                card_font, foreground, ass_escape(line)
            )
        end
        y = by + card_gap
    end

    live_overlay.res_x, live_overlay.res_y = width, height
    live_overlay.data = table.concat(events, '\n')
    live_overlay:update()
    refresh_live_close_target()
end

local function clear_live_overlay()
    clear_live_close_binding()
    live_overlay:remove()
end

local function path_key(path)
    return (path or ''):gsub('\\', '/'):lower()
end

local function media_paths()
    return {
        mp.get_property('path') or '',
        mp.get_property('stream-open-filename') or '',
    }
end

local function playlist_item()
    local position = mp.get_property_number('playlist-pos', -1)
    local playlist = mp.get_property_native('playlist') or {}
    return position >= 0 and playlist[position + 1] or nil
end

local function playlist_filename()
    local item = playlist_item()
    return item and (item.filename or item.path) or ''
end

local function source_candidates()
    local candidates, seen = {}, {}
    local function add(path)
        if type(path) == 'string' and path ~= '' and not seen[path] then
            seen[path] = true
            table.insert(candidates, path)
        end
    end
    -- The playlist filename remains the original webpage URL in builds where
    -- `path` and `stream-open-filename` have already become a media stream.
    add(playlist_filename())
    for _, path in ipairs(media_paths()) do add(path) end
    return candidates
end

local function bilibili_host(path)
    if type(path) ~= 'string' then return nil end
    local host = path:match('^https?://([^/%?#:]+)')
    host = host and host:lower() or nil
    if host == 'bilibili.com' or (host and host:match('%.bilibili%.com$')) then return host end
end

local function query_parameter(path, wanted_key)
    local query = type(path) == 'string' and path:match('%?([^#]*)') or nil
    for parameter in (query or ''):gmatch('[^&]+') do
        local key, value = parameter:match('^([^=]+)=?(.*)$')
        if key and key:lower() == wanted_key then return value end
    end
    return nil
end

local function parse_bilibili_video(path)
    if not bilibili_host(path) then return nil end
    -- Festival and campaign pages carry the playable BV id as ?bvid=BV..., so
    -- recognize it before the page URL is replaced by yt-dlp's media stream.
    local bvid = path:match('/video/([Bb][Vv][%w]+)') or query_parameter(path, 'bvid')
    if type(bvid) ~= 'string' or not bvid:match('^[Bb][Vv][%w]+$') then return nil end
    local page = tonumber(query_parameter(path, 'p')) or 1
    return bvid, page
end

local function parse_bilibili_live(path)
    if type(path) ~= 'string' then return nil end

    -- Bilibili uses several equivalent room routes.  The page-context script
    -- already recognizes /blanc/<room>; keep the sending/receiver path parser
    -- in sync so a modern live URL does not lose its send capability.
    local room_id = path:match('live%.bilibili%.com/blanc/(%d+)')
        or path:match('live%.bilibili%.com/h5/(%d+)')
        or path:match('live%.bilibili%.com/(%d+)')
    return room_id and tonumber(room_id) or nil
end

local function shared_source_context()
    local shared = mp.get_property_native('user-data/web_source/context')
    if type(shared) ~= 'table' or type(shared.url) ~= 'string' then return nil end
    -- `web_source_context` is updated asynchronously around playlist switches.
    -- Do not let the previous entry's Bilibili URL win over the new playlist
    -- item while that handoff is still in flight.
    local item = playlist_item()
    if item and item.id ~= nil and shared.entry_id ~= nil
        and tostring(item.id) ~= tostring(shared.entry_id) then
        return nil
    end
    if shared.kind == 'bilibili-live' then
        local room_id = parse_bilibili_live(shared.url)
        if room_id then return {kind = 'live', room_id = room_id, path = shared.url, entry_id = shared.entry_id} end
    elseif shared.kind == 'bilibili-video' then
        local bvid, page = parse_bilibili_video(shared.url)
        if bvid then return {kind = 'video', bvid = bvid, page = page, path = shared.url, entry_id = shared.entry_id} end
    end
end

local function remember_source_context()
    local previous = source_context
    source_generation = source_generation + 1
    local shared = shared_source_context()
    if shared then
        shared.generation = source_generation
        source_context = shared
        return
    end
    local item = playlist_item()
    local playlist_path = item and (item.filename or item.path) or ''
    local playlist_entry_id = item and item.id or nil
    local discovered = nil
    for _, path in ipairs(source_candidates()) do
        local room_id = parse_bilibili_live(path)
        if room_id then
            discovered = { generation = source_generation, kind = 'live', room_id = room_id, path = path, entry_id = playlist_entry_id }
            break
        end
        local bvid, page = parse_bilibili_video(path)
        if bvid then
            discovered = { generation = source_generation, kind = 'video', bvid = bvid, page = page, path = path, entry_id = playlist_entry_id }
            break
        end
    end
    if discovered then
        source_context = discovered
        return
    end

    -- While yt-dlp opens or reloads a live stream it can replace every exposed
    -- URL with the resolved HLS/FLV address.  Preserve the previous Bilibili
    -- page context when that happens for the same playlist item.
    local same_entry = previous and previous.entry_id ~= nil and playlist_entry_id ~= nil
        and tostring(previous.entry_id) == tostring(playlist_entry_id)
    if previous and (same_entry or (playlist_path ~= '' and playlist_path == previous.path)) then
        previous.generation = source_generation
        source_context = previous
    else
        source_context = { generation = source_generation, entry_id = playlist_entry_id }
    end
end

local function current_path()
    local paths = media_paths()
    return paths[1] ~= '' and paths[1] or paths[2]
end

local function temporary_path(label, token, extension)
    -- The metadata response and the overlay manifest are both JSON.  They can
    -- be requested within the same wall-clock second, so the old
    -- BV/time/token-only filename could make the manifest overwrite the API
    -- response before the async chain had finished using it.
    temporary_serial = temporary_serial + 1
    local name = string.format('mpv-bilibili-%s-%d-%d-%d%s', label, os.time(), token, temporary_serial, extension)
    return utils.join_path(temp_dir, name)
end

local function cleanup_files(files, attempts)
    local remaining = {}
    for _, path in pairs(files or {}) do
        local removed, error = os.remove(path)
        if not removed and utils.file_info(path) then
            table.insert(remaining, path)
            mp.msg.verbose('[bilibili_danmaku] Cannot remove temporary file: ' .. (error or path))
        end
    end

    if #remaining > 0 and (attempts or 0) < 10 then
        mp.add_timeout(0.2, function() cleanup_files(remaining, (attempts or 0) + 1) end)
    elseif #remaining > 0 then
        mp.msg.warn('[bilibili_danmaku] Some temporary files could not be removed')
    end
end

local function cleanup_pending(token)
    local state = pending[token]
    pending[token] = nil
    if state then cleanup_files(state.files) end
end

local function clear_all_pending()
    for token in pairs(pending) do cleanup_pending(token) end
end

local function clear_active_vod()
    local state = active
    active = nil
    vod_overlay:remove()
    mp.set_property_native('user-data/bilibili_danmaku/vod-render-status', {active = false})
    if state then
        cleanup_files(state.files)
    end
end

local function ass_escape_event(value)
    return tostring(value or ''):gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}')
        :gsub('[\r\n]+', '\\N')
end

local function lower_bound(events, value)
    local first, last = 1, #events + 1
    while first < last do
        local middle = math.floor((first + last) / 2)
        if (tonumber(events[middle].start) or 0) < value then
            first = middle + 1
        else
            last = middle
        end
    end
    return first
end

local function upper_bound(events, value)
    local first, last = 1, #events + 1
    while first < last do
        local middle = math.floor((first + last) / 2)
        if (tonumber(events[middle].start) or 0) <= value then
            first = middle + 1
        else
            last = middle
        end
    end
    return first
end

local function vod_video_rect()
    local dimensions = mp.get_property_native('osd-dimensions') or {}
    local width, height = tonumber(dimensions.w), tonumber(dimensions.h)
    if not width or not height or width <= 0 or height <= 0 then return nil end
    local left, right = tonumber(dimensions.ml) or 0, tonumber(dimensions.mr) or 0
    local top, bottom = tonumber(dimensions.mt) or 0, tonumber(dimensions.mb) or 0
    local video_width, video_height = width - left - right, height - top - bottom
    if video_width <= 0 or video_height <= 0 then return nil end
    return width, height, left, top, video_width, video_height
end

local function overlay_target_fps()
    local fps = mp.get_property_number('display-fps', 0) or 0
    if fps <= 0 then fps = mp.get_property_number('estimated-display-fps', 0) or 0 end
    if fps <= 0 then fps = 60 end
    return math.min(240, math.max(1, math.floor(fps + 0.5)))
end

local function rebase_vod_clock(state, playback_time)
    local current = playback_time
    if current == nil then current = mp.get_property_number('playback-time', nil) end
    if current == nil then return end
    state.clock_time = current
    state.clock_updated_at = mp.get_time()
    state.clock_speed = mp.get_property_number('speed', 1) or 1
end

local function current_vod_time(state)
    local playback_time = mp.get_property_number('playback-time', nil)
    if state.clock_time == nil or state.clock_updated_at == nil then
        rebase_vod_clock(state, playback_time)
    end
    if state.clock_time == nil or state.clock_updated_at == nil then return playback_time end
    -- Freeze the danmaku clock whenever the media timeline is not advancing:
    -- explicit pause, or network buffering of a web video (paused-for-cache
    -- stays false on `pause`, otherwise the monotonic estimate would keep the
    -- danmaku flying past a stalled frame, breaking Bilibili-style sync).
    local stalled = mp.get_property_bool('pause', false)
        or mp.get_property_bool('paused-for-cache', false)
    if stalled then return playback_time or state.clock_time end

    local now = mp.get_time()
    local speed = mp.get_property_number('speed', 1) or 1
    local elapsed = now - state.clock_updated_at
    local predicted = state.clock_time + elapsed * (state.clock_speed or speed)
    if speed ~= state.clock_speed then
        state.clock_time, state.clock_updated_at, state.clock_speed = predicted, now, speed
        predicted = state.clock_time
    end

    -- playback-time is commonly updated at the decoded video cadence. Keep it
    -- as a drift/seek correction only, so OSD positions advance at display rate.
    if playback_time and math.abs(playback_time - predicted) > 0.15 then
        rebase_vod_clock(state, playback_time)
        return playback_time
    end
    return predicted
end

local function update_vod_render_status(state)
    local now = mp.get_time()
    state.render_started_at = state.render_started_at or now
    state.render_frames = (state.render_frames or 0) + 1
    local elapsed = now - state.render_started_at
    if elapsed < 0.5 then return end
    mp.set_property_native('user-data/bilibili_danmaku/vod-render-status', {
        active = true,
        target_fps = overlay_target_fps(),
        actual_fps = state.render_frames / elapsed,
        clock = 'monotonic',
        paused = false,
    })
    state.render_started_at, state.render_frames = now, 0
end

local function render_vod_overlay()
    local state = active
    if not state then
        vod_overlay:remove()
        return
    end

    local now = current_vod_time(state)
    local width, height, left, top, video_width, video_height = vod_video_rect()
    if not now or not width then return end
    update_vod_render_status(state)

    local stage = state.stage
    local scale_x = video_width / stage.width
    local scale_y = video_height / stage.height
    -- 显示区域: keep full scale for font/outline, but map the danmaku play
    -- field into the requested top fraction of the frame (Bilibili web style).
    local area_frac = math.max(area_min, math.min(area_max, render_area)) / 100
    local y_scale_y = scale_y * area_frac
    local start_index = lower_bound(state.events, now - state.max_duration)
    local end_index = upper_bound(state.events, now) - 1
    local events = {}
    local opacity_frac = math.max(0, math.min(1, render_opacity / 100))
    local alpha = math.max(0, math.min(255, 255 - math.floor((state.opacity or 1) * opacity_frac * 255 + 0.5)))

    for index = start_index, end_index do
        local event = state.events[index]
        local start_time = tonumber(event.start)
        local end_time = tonumber(event['end'])
        if start_time and end_time and start_time <= now and now < end_time then
            local mode = event.mode
            local x, y, alignment
            if mode == 'rtl' or mode == 'ltr' then
                local progress = (now - start_time) / math.max(end_time - start_time, 0.001)
                local x_start = tonumber(event.x_start) or 0
                local x_end = tonumber(event.x_end) or 0
                x = x_start + (x_end - x_start) * progress
                y = tonumber(event.y) or 0
                alignment = 7
            elseif mode == 'top' then
                x, y, alignment = tonumber(event.x) or 0, tonumber(event.y) or 0, 8
            elseif mode == 'bottom' then
                x, y, alignment = tonumber(event.x) or 0, tonumber(event.y) or 0, 2
            end

            if alignment then
                local color = color_to_ass(event.color)
                local font_size = math.max(1, tonumber(event.font_size) or state.font_size) * font_scale
                -- 细描边: thin black outline, re-scaled with the danmaku field.
                local bord = math.max(1.5, font_size * scale_y * 0.04)
                events[#events + 1] = string.format(
                    '{\\an%d\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\b1\\bord%.1f\\shad0\\3c&H000000&\\1c&H%s&\\alpha&H%02X&}%s',
                    alignment, left + x * scale_x, top + y * y_scale_y, DANMAKU_FONT,
                    font_size * scale_y, bord, color, alpha,
                    ass_escape_event(event.text)
                )
            end
        end
    end

    if #events == 0 then
        vod_overlay:remove()
        return
    end
    vod_overlay.res_x, vod_overlay.res_y = width, height
    vod_overlay.data = table.concat(events, '\n')
    vod_overlay:update()
end

local function live_has_visible_items()
    return live_state and (#(live_state.normal or {}) > 0 or #(live_state.cards or {}) > 0)
end

local function update_live_render_status()
    local state = live_state
    local now = mp.get_time()
    if not state or not live_has_visible_items() then
        mp.set_property_native('user-data/bilibili_danmaku/live-render-status', {
            active = false,
            connected = state and state.ready or false,
        })
        return
    end

    state.render_started_at = state.render_started_at or now
    state.render_frames = (state.render_frames or 0) + 1
    local elapsed = now - state.render_started_at
    if elapsed < 0.5 then
        mp.set_property_native('user-data/bilibili_danmaku/live-render-status', {
            active = true,
            connected = state.ready == true,
            target_fps = overlay_target_fps(),
            actual_fps = 0,
            clock = 'monotonic',
        })
        return
    end
    mp.set_property_native('user-data/bilibili_danmaku/live-render-status', {
        active = true,
        connected = state.ready == true,
        target_fps = overlay_target_fps(),
        actual_fps = state.render_frames / elapsed,
        clock = 'monotonic',
    })
    state.render_started_at, state.render_frames = now, 0
end

local function vod_clock_advancing()
    return mp.get_property_bool('pause', false) == false
        and mp.get_property_bool('paused-for-cache', false) == false
end

local function render_danmaku_overlays()
    if live_state then
        render_live_overlay()
        update_live_render_status()
    end
    if active and vod_clock_advancing() then render_vod_overlay() end
    if update_render_timer then update_render_timer() end
end

update_render_timer = function()
    if not render_timer then return end
    local target = overlay_target_fps()
    if target ~= render_timer_fps then
        render_timer:kill()
        render_timer.timeout = 1 / target
        render_timer_fps = target
    end
    local vod_is_playing = active and vod_clock_advancing()
    local has_moving_overlay = vod_is_playing or live_has_visible_items()
    if has_moving_overlay then
        -- Calling resume() from inside every periodic callback restarts the
        -- timer cadence on some Windows builds.  Only wake a stopped timer.
        if not render_timer:is_enabled() then render_timer:resume() end
    elseif render_timer:is_enabled() then
        render_timer:kill()
    end
end

local function current_bilibili_video()
    if source_context and source_context.kind == 'video' then
        return source_context.bvid, source_context.page, source_context.path
    end
    for _, path in ipairs(source_candidates()) do
        local bvid, page = parse_bilibili_video(path)
        if bvid then return bvid, page, path end
    end
end

local function current_bilibili_live()
    -- Prefer the shared page context.  It is updated by web_source_context
    -- before yt-dlp swaps the visible URL for the stream, and unlike the
    -- local cache it cannot lag one lifecycle turn behind a quality reload.
    local shared = shared_source_context()
    if shared and shared.kind == 'live' then
        return shared.room_id, shared.path
    end
    if source_context and source_context.kind == 'live' then
        return source_context.room_id, source_context.path
    end
    for _, path in ipairs(source_candidates()) do
        local room_id = parse_bilibili_live(path)
        if room_id then return room_id, path end
    end
end

local function current_source_kind()
    local room_id, live_path = current_bilibili_live()
    if room_id then return 'live', room_id, live_path end
    local bvid, page, video_path = current_bilibili_video()
    if bvid then return 'video', bvid, page, video_path end
    return nil
end

local function live_refresh_active()
    local context = live_refresh_context
    if not context then return false end
    if context.expires_at <= mp.get_time() then
        live_refresh_context = nil
        return false
    end
    return true
end

local function capture_live_refresh_context()
    local kind, room_id, source_path = current_source_kind()
    if kind ~= 'live' or not room_id then return end
    local item = playlist_item()
    live_refresh_context = {
        room_id = room_id,
        path = source_path,
        entry_id = item and item.id or nil,
        expires_at = mp.get_time() + 30,
        keep_receiver = true,
    }
end

local function refresh_matches_playlist_entry(entry_id)
    if not live_refresh_active() then return false end
    if entry_id == nil then
        local item = playlist_item()
        entry_id = item and item.id or nil
    end
    local refresh_entry_id = live_refresh_context.entry_id
    return refresh_entry_id == nil or entry_id == nil
        or tostring(refresh_entry_id) == tostring(entry_id)
end

local function restore_live_refresh_context(entry_id)
    entry_id = entry_id or (playlist_item() and playlist_item().id or nil)
    if not refresh_matches_playlist_entry(entry_id) or current_source_kind() then return end
    local item = playlist_item()
    source_context = {
        generation = source_generation,
        kind = 'live',
        room_id = live_refresh_context.room_id,
        path = live_refresh_context.path,
        entry_id = item and item.id or nil,
    }
end

local function preserve_live_receiver_for_refresh(entry_id)
    -- Playback teardown events can be delivered before or after the new
    -- file-loaded notification.  Keep the receiver alive for the entire
    -- explicit refresh transaction; a genuinely different source is still
    -- stopped by apply_settings_to_current().
    return refresh_matches_playlist_entry(entry_id)
end

local function update_live_send_availability()
    if mp.get_property_bool('idle-active', false) then
        mp.set_property_bool('user-data/bilibili_danmaku/available', false)
        mp.set_property('user-data/bilibili_danmaku/source-kind', '')
        mp.set_property_bool('user-data/bilibili_danmaku/live-send-available', false)
        mp.set_property('user-data/bilibili_danmaku/live-send-source', '')
        return
    end

    local kind, room_id = current_source_kind()
    mp.set_property_bool('user-data/bilibili_danmaku/available', kind ~= nil)
    mp.set_property('user-data/bilibili_danmaku/source-kind', kind or '')
    local available = kind == 'live' and room_id ~= nil
    mp.set_property_bool('user-data/bilibili_danmaku/live-send-available', available)
    mp.set_property('user-data/bilibili_danmaku/live-send-source', available and ('room:' .. tostring(room_id)) or '')
end

local function is_current_source(path)
    if source_context and source_context.path == path then return true end
    if path == playlist_filename() then return true end
    for _, candidate in ipairs(media_paths()) do
        if candidate == path then return true end
    end
    return false
end

local function notify_uosc(name, payload)
    mp.commandv('script-message-to', 'uosc', name, utils.format_json(payload or {}))
end

local function finish_loading()
    loading = false
    loading_source_path = nil
end

local function cancel_vod_request(token)
    cleanup_pending(token)
    if token == request_id then finish_loading() end
end

local function fail(message, detail)
    finish_loading()
    if detail and detail ~= '' then mp.msg.warn('[bilibili_danmaku] ' .. detail) end
    mp.osd_message(message, 3)
end

local function run_async(args, callback)
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        if not success or not result or result.status ~= 0 then
            local detail = error
                or (result and (result.error_string or result.stderr))
                or 'unknown subprocess error'
            callback(nil, detail)
            return
        end
        callback(result, nil)
    end)
end

local function send_live_danmaku(json)
    local event = utils.parse_json(json or '')
    local request_id = type(event) == 'table' and event.id or nil
    local message = type(event) == 'table' and event.message or nil
    local function reply(ok, error)
        notify_uosc('live-danmaku-send-result', {id = request_id, ok = ok, error = error})
    end

    if type(request_id) ~= 'number' or type(message) ~= 'string' then return end
    if live_send_in_progress then
        reply(false, '正在发送弹幕，请稍候')
        return
    end
    if not message:match('%S') then
        reply(false, '请输入弹幕')
        return
    end

    local kind, room_id = current_source_kind()
    if kind ~= 'live' or not room_id then
        update_live_send_availability()
        reply(false, '当前不是 Bilibili 直播间')
        return
    end
    if not utils.file_info(python) or not utils.file_info(live_sender) or not utils.file_info(bridge) then
        reply(false, '直播弹幕发送组件不可用')
        return
    end

    local send_state = live_state
    if send_state and tostring(send_state.room_id) ~= tostring(room_id) then send_state = nil end
    local pending_self_message = track_pending_self_message(send_state, request_id, message)
    live_send_in_progress = true
    run_async({python, live_sender, '--room', tostring(room_id), '--message', message, '--bridge', bridge},
        function(result, process_error)
            live_send_in_progress = false
            local payload = result and utils.parse_json(result.stdout or '') or nil
            if type(payload) == 'table' then
                local ok = payload.ok == true
                if ok and pending_self_message and live_state == send_state then
                    if pending_self_message.received then
                        remove_pending_self_message(send_state, pending_self_message)
                    elseif enabled.normal and queue_live_normal then
                        pending_self_message.echoed = queue_live_normal(send_state, {
                            text = message,
                            color = 0xFFFFFF,
                            is_self = true,
                        })
                    end
                elseif pending_self_message then
                    remove_pending_self_message(send_state, pending_self_message)
                end
                reply(ok, ok and nil or tostring(payload.error or '弹幕发送失败'))
            else
                remove_pending_self_message(send_state, pending_self_message)
                reply(false, process_error or '弹幕发送失败')
            end
        end)
end

local function add_proxy_and_cookie(args, _style)
    -- Bilibili web and live-danmaku endpoints must use the direct route here.
    -- The global mpv proxy is still passed to the Chrome Bridge for YouTube,
    -- but on this network it makes Bilibili Live return an empty playurl and
    -- can also prevent its WebSocket handshake.  The bridge supplies cookies
    -- from memory, so there is nothing else to append for Bilibili.
    return args
end

local function bilibili_fetch_args(url, output)
    -- The Python helper reads Chrome Bridge cookies when the extension is
    -- available, then falls back to Bilibili's public endpoints. The bridge's
    -- direct fetch command has no fallback when its MV3 service is dormant.
    local args = { python, bilibili_fetcher, '--bridge', bridge, '--url', url, '--user-agent', BILIBILI_USER_AGENT }
    if output then
        table.insert(args, '--output')
        table.insert(args, output)
    end
    add_proxy_and_cookie(args)
    return args
end

local function stop_vod(message)
    request_id = request_id + 1
    finish_loading()
    clear_all_pending()
    clear_active_vod()
    mp.set_property_native('user-data/bilibili_danmaku/vod-load-status', {phase = 'idle'})
    if update_render_timer then update_render_timer() end
    if message then mp.osd_message(message, 2) end
end

local function mount_danmaku(path, source_path, token)
    if not loading or not enabled.normal or not is_current_source(source_path) then
        cancel_vod_request(token)
        return
    end
    local file = io.open(path, 'rb')
    local contents = file and file:read('*all') or nil
    if file then file:close() end
    local manifest = contents and utils.parse_json(contents) or nil
    local stage = manifest and manifest.stage or nil
    if type(manifest) ~= 'table' or manifest.version ~= 1 or type(stage) ~= 'table'
        or type(manifest.events) ~= 'table' or tonumber(stage.width) == nil or tonumber(stage.height) == nil then
        cleanup_pending(token)
        fail('弹幕渲染数据加载失败', 'Invalid Bilibili danmaku overlay manifest')
        return
    end
    if tonumber(stage.width) <= 0 or tonumber(stage.height) <= 0 then
        cleanup_pending(token)
        fail('弹幕渲染数据加载失败', 'Invalid Bilibili danmaku overlay stage')
        return
    end

    table.sort(manifest.events, function(a, b)
        return (tonumber(a.start) or 0) < (tonumber(b.start) or 0)
    end)
    local max_duration = 0
    for _, event in ipairs(manifest.events) do
        local start_time, end_time = tonumber(event.start), tonumber(event['end'])
        local duration = start_time and end_time and end_time - start_time or nil
        if type(duration) == 'number' and duration >= 0 then
            max_duration = math.max(max_duration, duration)
        end
    end

    local state = pending[token]
    if not state then
        if token == request_id then finish_loading() end
        return
    end
    pending[token] = nil
    active = {
        source_path = source_path,
        files = state.files,
        events = manifest.events,
        stage = {width = tonumber(stage.width), height = tonumber(stage.height)},
        font = tostring(stage.font or 'Microsoft YaHei'),
        font_size = tonumber(stage.font_size) or 45,
        outline = tonumber(stage.outline) or 1,
        opacity = tonumber(stage.opacity) or 1,
        max_duration = math.max(max_duration, 0.001),
    }
    rebase_vod_clock(active)
    finish_loading()
    -- A paused player intentionally has no periodic render callback. Publish
    -- the mounted state now so diagnostics do not report a false inactive
    -- overlay until playback resumes.
    mp.set_property_native('user-data/bilibili_danmaku/vod-render-status', {
        active = true,
        target_fps = overlay_target_fps(),
        actual_fps = 0,
        clock = 'monotonic',
        paused = mp.get_property_bool('pause', false),
    })
    render_vod_overlay()
    if update_render_timer then update_render_timer() end
    local skipped = tonumber(manifest.skipped_advanced) or 0
    if skipped > 0 then
        mp.osd_message(string.format('已开启 Bilibili 弹幕（已跳过 %d 条高级弹幕）', skipped), 3)
    else
        mp.osd_message('已开启 Bilibili 弹幕', 2)
    end
end

local function remove_automatic_bilibili_danmaku()
    if not current_bilibili_video() then return end
    local ids = {}
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        local filename = path_key(track['external-filename'] or track.external_filename)
        if track.type == 'sub' and (track.lang == 'danmaku' or filename:find('comment.bilibili.com', 1, true)) then
            table.insert(ids, track.id)
        end
    end
    for _, id in ipairs(ids) do
        if mp.get_property_number('sid', 0) == id then mp.set_property_number('sid', 0) end
        if mp.get_property_number('secondary-sid', 0) == id then mp.set_property_number('secondary-sid', 0) end
        pcall(mp.commandv, 'sub-remove', tostring(id))
    end
end

local function read_file(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local contents = file:read('*all')
    file:close()
    return contents
end

local function vod_request_is_current(token, source_path)
    return loading and token == request_id and enabled.normal and is_current_source(source_path)
end

-- On some Windows builds, command_native_async can write an output file but
-- never deliver the nested Lua callback.  Point danmaku has three dependent
-- file-producing steps, so use the output itself as the completion signal.
local function start_vod_output_job(token, source_path, phase, args, output_path, decode, on_ready, error_message, error_path)
    local finished = false
    local deadline = mp.get_time() + 20
    mp.set_property_native('user-data/bilibili_danmaku/vod-load-status', {
        phase = phase,
        token = token,
        source = source_path,
    })

    local function fail_job(detail)
        if finished then return end
        finished = true
        if token == request_id then
            mp.set_property_native('user-data/bilibili_danmaku/vod-load-status', {
                phase = 'failed',
                token = token,
                source = source_path,
                detail = detail,
            })
            cleanup_pending(token)
            fail(error_message, detail)
        end
    end

    local function watch_output()
        if finished then return end
        if not vod_request_is_current(token, source_path) then
            finished = true
            cancel_vod_request(token)
            return
        end

        local contents = read_file(output_path)
        local decoded = contents and decode(contents) or nil
        if decoded ~= nil then
            finished = true
            on_ready(decoded)
            return
        end

        local job_error = error_path and read_file(error_path) or nil
        if job_error and job_error ~= '' then
            fail_job(job_error)
            return
        end

        if mp.get_time() >= deadline then
            fail_job('Timed out waiting for ' .. phase .. ' output')
            return
        end
        mp.add_timeout(0.05, watch_output)
    end

    -- mpv can report an empty async error before a Windows child process has
    -- finished flushing its redirected output.  Start the job here, but use
    -- only the output watcher below for both completion and failure.
    run_async(args, function() end)
    watch_output()
end

local function get_cid_and_download(token, bvid, page, source_path)
    local api_file = temporary_path(bvid, token, '.api.json')
    local xml_file = temporary_path(bvid, token, '.xml')
    local overlay_file = temporary_path(bvid, token, '.overlay.json')
    local error_file = temporary_path(bvid, token, '.error.txt')
    pending[token] = { files = { api = api_file, xml = xml_file, overlay = overlay_file, error = error_file } }

    local width = math.max(1, mp.get_property_number('video-params/w', 1920))
    local height = math.max(1, mp.get_property_number('video-params/h', 1080))
    local args = {
        python, vod_pipeline,
        '--bvid', bvid, '--page', tostring(page), '--width', tostring(width), '--height', tostring(height),
        '--bridge', bridge, '--fetcher', bilibili_fetcher, '--converter', converter,
        '--api-output', api_file, '--xml-output', xml_file, '--overlay-output', overlay_file,
        '--error-output', error_file, '--user-agent', BILIBILI_USER_AGENT,
    }
    start_vod_output_job(token, source_path, 'vod-pipeline', args, overlay_file,
        function(contents)
            local manifest = utils.parse_json(contents)
            if type(manifest) == 'table' and manifest.version == 1
                and type(manifest.stage) == 'table' and type(manifest.events) == 'table' then
                return manifest
            end
            return nil
        end,
        function()
            mount_danmaku(overlay_file, source_path, token)
        end,
        '加载 Bilibili 弹幕失败', error_file)
end

local function start_vod(bvid, page, source_path)
    if active and active.source_path == source_path then return end
    if loading then
        if loading_source_path == source_path then return end
        stop_vod()
    end
    if not utils.file_info(python) or not utils.file_info(converter) or not utils.file_info(bilibili_fetcher)
        or not utils.file_info(vod_pipeline) then
        mp.osd_message('弹幕转换组件不可用', 3)
        return
    end
    request_id = request_id + 1
    loading = true
    loading_source_path = source_path
    mp.osd_message('正在加载 Bilibili 弹幕', 2)
    get_cid_and_download(request_id, bvid, page, source_path)
end

local function write_stop_file(path)
    local file = io.open(path, 'wb')
    if file then file:close() end
end

queue_live_normal = function(state, event)
    local width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then return false end
    local now = mp.get_time()
    prune_live_items(state, now)
    local font_size = live_font_size(height)
    local line_height = math.max(font_size * 1.2, 1)
    -- 与 render_live_overlay 保持一致：车道数跟随显示区域，默认铺满整屏高度。
    local area_frac = math.max(area_min, math.min(area_max, render_area)) / 100
    local lane_count = math.max(1, math.floor((height * area_frac) / line_height))
    local text = normalized_live_text(event.text)
    if text == '' then return false end
    local duration = 8
    local message_width = math.max(1, estimate_text_width(text, font_size))
    local lane = nil
    for index = 1, lane_count do
        local previous = state.lane_last[index]
        if not previous then
            lane = index
            break
        end
        local safe_delay = previous.width * previous.duration / (width + previous.width) + 0.12
        if now - previous.started_at >= safe_delay then
            lane = index
            break
        end
    end
    if not lane then return false end -- Drop only the message that would overlap.
    local color = color_to_ass(event.color)
    local message = {
        text = text,
        color = color,
        width = message_width,
        lane = lane,
        started_at = now,
        expires_at = now + duration,
        duration = duration,
        is_self = event.is_self == true,
    }
    state.normal[#state.normal + 1] = message
    state.lane_last[lane] = message
    local first_rendered = (state.rendered_normal or 0) == 0
    state.rendered_normal = (state.rendered_normal or 0) + 1
    update_live_status()
    if first_rendered then
        if update_open_menu then update_open_menu() end
    end
    render_live_overlay()
    if update_render_timer then update_render_timer() end
    return true
end

local function queue_live_superchat(state, event)
    local now = mp.get_time()
    prune_live_items(state, now)
    local duration = tonumber(event.duration) or 30
    state.cards[#state.cards + 1] = {
        id = tostring(event.id or (now .. '-' .. #state.cards)),
        user = tostring(event.user or '醒目留言'),
        text = tostring(event.text or ''),
        color = event.color,
        price = event.price,
        expires_at = now + math.max(1, math.min(duration, 3600)),
    }
    local first_rendered = (state.rendered_superchat or 0) == 0
    state.rendered_superchat = (state.rendered_superchat or 0) + 1
    update_live_status()
    if first_rendered then
        if update_open_menu then update_open_menu() end
    end
    render_live_overlay()
    if update_render_timer then update_render_timer() end
end

local function clear_live_normal()
    if not live_state then return end
    live_state.normal, live_state.lane_last = {}, {}
    render_live_overlay()
    if update_render_timer then update_render_timer() end
end

local function clear_live_superchat()
    if not live_state then return end
    live_state.cards = {}
    render_live_overlay()
    if update_render_timer then update_render_timer() end
end

local function process_live_event(state, event)
    if live_state ~= state or state.token ~= request_id then return end
    if event.type == 'ready' then
        if not state.ready then mp.osd_message('已连接 Bilibili 直播弹幕', 2) end
        state.ready = true
        state.self_user_id = tonumber(event.user_id) or nil
        state.last_error, state.error_shown = nil, false
        update_live_status()
        if update_open_menu then update_open_menu() end
        mp.add_timeout(15, function()
            if live_state == state and state.ready and (state.received_normal or 0) == 0 and enabled.normal then
                mp.osd_message('已连接直播弹幕，等待房间的新弹幕', 3)
            end
        end)
    elseif event.type == 'normal' then
        state.received_normal = (state.received_normal or 0) + 1
        local is_self = state.self_user_id and state.self_user_id > 0
            and tonumber(event.user_id) == state.self_user_id
        local suppress = false
        if is_self then
            event.is_self = true
            local pending_self_message = find_pending_self_message(state, event.text)
            if pending_self_message then
                pending_self_message.received = true
                if pending_self_message.echoed then
                    remove_pending_self_message(state, pending_self_message)
                    suppress = true
                end
            end
        end
        if enabled.normal then
            if suppress then
                update_live_status()
            else
                queue_live_normal(state, event)
            end
        else
            update_live_status()
        end
    elseif event.type == 'superchat' then
        state.received_superchat = (state.received_superchat or 0) + 1
        if enabled.superchat then
            queue_live_superchat(state, event)
        else
            update_live_status()
        end
    elseif event.type == 'error' and not state.error_shown then
        state.error_shown = true
        state.last_error = tostring(event.message or 'unknown error')
        update_live_status()
        if update_open_menu then update_open_menu() end
        mp.msg.warn('[bilibili_danmaku] Live receiver: ' .. state.last_error)
        mp.osd_message('直播弹幕连接失败，正在重试', 3)
    end
end

local function poll_live_events()
    local state = live_state
    if not state then return end
    -- yt-dlp replaces the page URL with an HLS/FLV stream.  The old URL
    -- equality check therefore stopped polling precisely after a successful
    -- live load.  Session identity is the authoritative lifetime boundary;
    -- stop_live() invalidates it when the media changes.
    if state.token ~= request_id then return end
    local file = io.open(state.events_path, 'rb')
    if not file then return end
    file:seek('set', state.offset)
    local data = file:read('*all') or ''
    state.offset = file:seek() or state.offset
    file:close()
    if data == '' then return end
    state.buffer = state.buffer .. data
    while true do
        local end_at = state.buffer:find('\n', 1, true)
        if not end_at then break end
        local line = state.buffer:sub(1, end_at - 1)
        state.buffer = state.buffer:sub(end_at + 1)
        local event = utils.parse_json(line)
        if type(event) == 'table' then process_live_event(state, event) end
    end
end

local function stop_live()
    local state = live_state
    live_state = nil
    if live_poll_timer then live_poll_timer:kill() end
    clear_live_overlay()
    notify_uosc('live-danmaku-clear')
    notify_uosc('live-superchat-clear')
    update_live_status()
    mp.set_property_native('user-data/bilibili_danmaku/live-render-status', {
        active = false,
        connected = false,
        target_fps = overlay_target_fps(),
        actual_fps = 0,
        clock = 'monotonic',
    })
    if update_render_timer then update_render_timer() end
    if not state then return end
    write_stop_file(state.stop_path)
    mp.add_timeout(2, function() cleanup_files({state.events_path, state.stop_path}) end)
end

local function fail_live_refresh()
    if not live_refresh_context then return end
    live_refresh_context = nil
    stop_live()
end

local function start_live(room_id, source_path)
    -- The Bilibili page URL can change shape while yt-dlp resolves the stream
    -- (for example, between a room URL and a shared page-context URL).  That
    -- does not mean the viewer changed rooms, so keep the receiver and the
    -- existing normal danmaku alive.
    if live_state and live_state.room_id == room_id then
        live_state.source_path = source_path
        return
    end
    if not utils.file_info(live_python) or not utils.file_info(live_receiver) then
        mp.osd_message('直播弹幕组件不可用', 3)
        return
    end
    stop_live()
    request_id = request_id + 1
    local token = request_id
    local state = {
        token = token,
        room_id = room_id,
        source_path = source_path,
        events_path = temporary_path('live-' .. tostring(room_id), token, '.jsonl'),
        stop_path = temporary_path('live-' .. tostring(room_id), token, '.stop'),
        offset = 0,
        buffer = '',
        ready = false,
        error_shown = false,
        normal = {},
        lane_last = {},
        cards = {},
        pending_self_messages = {},
        self_user_id = nil,
        received_normal = 0,
        rendered_normal = 0,
        received_superchat = 0,
        rendered_superchat = 0,
    }
    local initial = io.open(state.events_path, 'wb')
    if initial then initial:close() end
    live_state = state
    mp.set_property_native('user-data/bilibili_danmaku/live-render-status', {
        active = false,
        connected = false,
        target_fps = overlay_target_fps(),
        actual_fps = 0,
        clock = 'monotonic',
    })
    local args = {live_python, live_receiver, '--room', tostring(room_id), '--output', state.events_path, '--stop', state.stop_path, '--bridge', bridge}
    add_proxy_and_cookie(args, 'live')
    local ok, err = pcall(utils.subprocess_detached, {args = args, cancellable = false, playback_only = false})
    if not ok then
        live_state = nil
        cleanup_files({state.events_path, state.stop_path})
        mp.osd_message('启动直播弹幕组件失败', 3)
        mp.msg.warn('[bilibili_danmaku] Could not start live receiver: ' .. tostring(err))
        update_live_status()
        if update_render_timer then update_render_timer() end
        return
    end
    if live_poll_timer then live_poll_timer:resume() end
    if update_render_timer then update_render_timer() end
    update_live_status()
    mp.osd_message('正在连接 Bilibili 直播弹幕', 2)
end

local function restore_live_after_refresh()
    local context = live_refresh_context
    if not context then return end
    if mp.get_property_bool('idle-active', false) then
        fail_live_refresh()
        return
    end

    local item = playlist_item()
    if not refresh_matches_playlist_entry(item and item.id or nil) then return end
    source_context = {
        generation = source_generation,
        kind = 'live',
        room_id = context.room_id,
        path = context.path,
        entry_id = item and item.id or context.entry_id,
    }
    context.keep_receiver = false
    context.expires_at = mp.get_time() + 10

    if enabled.normal or enabled.superchat then
        start_live(context.room_id, context.path)
    else
        stop_live()
    end
    update_live_send_availability()
    if update_open_menu then update_open_menu() end
end

local function apply_settings_to_current()
    local kind, a, b, c = current_source_kind()
    if kind == 'video' then
        stop_live()
        if enabled.normal then
            start_vod(a, b, c)
        else
            stop_vod()
        end
    elseif kind == 'live' then
        stop_vod()
        if not enabled.normal then clear_live_normal() end
        if not enabled.superchat then clear_live_superchat() end
        if enabled.normal or enabled.superchat then
            start_live(a, b)
        else
            stop_live()
        end
    else
        stop_vod()
        stop_live()
    end
end

local function step_number(current, delta, lo, hi)
    return math.max(lo, math.min(hi, current + delta))
end

-- 构造一个带 "减少/增加" 按钮的可调参数菜单项。
-- 当前数值会直接拼进 title（如 "显示区域：100%"），避免与 +/− 按钮重叠而显示不出。
local function param_menu_item(value, title)
    return {
        title = title,
        value = value,
        active = true,
        selectable = true,
        keep_open = true,
        actions_place = 'inside',
        actions_always_visible = true,
        actions_text = true,
        actions = {
            { name = 'dec', label = '-', tooltip = '减少' },
            { name = 'inc', label = '+', tooltip = '增加' },
        },
    }
end

local function menu_data()
    local kind = not mp.get_property_bool('idle-active', false) and current_source_kind() or nil
    local is_video, is_live = kind == 'video', kind == 'live'
    local items = {}
    if is_live then
        local state = live_state
        local status
        if not state then
            status = '直播状态：已关闭'
        elseif state.ready then
            status = string.format(
                '直播状态：已连接 · 普通 %d/%d · 醒目 %d/%d',
                state.received_normal or 0, state.rendered_normal or 0,
                state.received_superchat or 0, state.rendered_superchat or 0
            )
        else
            status = '直播状态：正在连接'
            if state.last_error and state.last_error ~= '' then status = status .. ' · ' .. state.last_error end
        end
        table.insert(items, {title = status, selectable = false, muted = true, align = 'center'})
    end
    table.insert(items, {
        title = '普通弹幕', hint = enabled.normal and '开启' or '关闭', value = 'normal',
        active = enabled.normal, selectable = is_video or is_live, keep_open = true,
        tooltip = is_video and '点播弹幕' or (is_live and '直播普通弹幕' or '当前不是 Bilibili 视频或直播'),
    })
    if is_live then
        table.insert(items, {
            title = '醒目留言', hint = enabled.superchat and '开启' or '关闭', value = 'superchat',
            active = enabled.superchat, selectable = true, keep_open = true,
            tooltip = '直播左侧醒目留言卡片',
        })
    end

    table.insert(items, {title = '参数设置', selectable = false, muted = true, align = 'center'})
    table.insert(items, param_menu_item('opacity', '不透明度：' .. render_opacity .. '%'))
    table.insert(items, param_menu_item('font', '字号：' .. math.floor(font_scale * 100 + 0.5) .. '%'))

    return {
        type = 'bilibili-danmaku',
        title = 'Bilibili 弹幕',
        search_style = 'disabled',
        keep_open = true,
        callback = {'bilibili_danmaku', 'menu-event'},
        items = items,
    }
end

update_open_menu = function()
    mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(menu_data()))
end

local function open_menu()
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu_data()))
end

local function menu_event(json)
    local event = utils.parse_json(json or '')
    if type(event) ~= 'table' or event.type ~= 'activate' then return end
    if event.action == 'inc' or event.action == 'dec' then
        local delta = (event.action == 'inc' and 1 or -1)
        if event.value == 'opacity' then
            render_opacity = step_number(render_opacity, delta * opacity_step, opacity_min, opacity_max)
            mp.osd_message(string.format('弹幕不透明度：%d%%', render_opacity), 1.2)
        elseif event.value == 'font' then
            font_scale = math.floor(step_number(font_scale, delta * font_scale_step, font_scale_min, font_scale_max) * 10 + 0.5) / 10
            mp.osd_message(string.format('弹幕字号：%d%%', math.floor(font_scale * 100 + 0.5)), 1.2)
        else
            return
        end
        save_persisted()
        update_open_menu()
        return
    end
    if event.value == 'normal' then
        enabled.normal = not enabled.normal
    elseif event.value == 'superchat' and current_source_kind() == 'live' then
        enabled.superchat = not enabled.superchat

        -- This switch owns only the right-side Super Chat cards.  Do not
        -- reapply the whole live session here: doing so can clear normal
        -- danmaku or reconnect the receiver when the page URL has changed.
        if not enabled.superchat then
            clear_live_superchat()
            if not enabled.normal then stop_live() end
        elseif not live_state then
            apply_settings_to_current()
        end
        update_open_menu()
        return
    else
        return
    end
    apply_settings_to_current()
    update_open_menu()
end

local function toggle()
    local kind = current_source_kind()
    if mp.get_property_bool('idle-active', false) or not kind then
        mp.osd_message('当前不是 Bilibili 视频或直播', 2)
        return
    end
    if kind == 'live' then
        local enable = not (enabled.normal and enabled.superchat)
        enabled.normal, enabled.superchat = enable, enable
    else
        enabled.normal = not enabled.normal
    end
    apply_settings_to_current()
    if kind == 'live' and enabled.normal and enabled.superchat then
        mp.osd_message('已开启 Bilibili 直播弹幕，正在连接', 2)
    elseif kind == 'live' then
        mp.osd_message('已关闭 Bilibili 直播弹幕', 2)
    elseif enabled.normal then
        mp.osd_message('正在加载 Bilibili 弹幕', 2)
    else
        mp.osd_message('已关闭 Bilibili 普通弹幕', 2)
    end
end

local function adjust_font_scale(delta)
    local next_scale = math.max(font_scale_min, math.min(font_scale_max, font_scale + delta))
    font_scale = math.floor(next_scale * 10 + 0.5) / 10
    mp.osd_message(string.format('弹幕字号：%d%%', math.floor(font_scale * 100 + 0.5)), 1.5)
    render_live_overlay()
    render_vod_overlay()
    save_persisted()
end

live_poll_timer = mp.add_periodic_timer(0.1, poll_live_events)
live_poll_timer:kill()
render_timer = mp.add_periodic_timer(1 / 60, render_danmaku_overlays)
render_timer:kill()
mp.observe_property('mouse-pos', 'native', function() refresh_live_close_target() end)
mp.observe_property('display-fps', 'number', function()
    update_render_timer()
end)
mp.observe_property('estimated-display-fps', 'number', function()
    update_render_timer()
end)
mp.observe_property('pause', 'bool', function()
    if active then
        rebase_vod_clock(active)
        render_vod_overlay()
    end
    update_render_timer()
end)
mp.observe_property('paused-for-cache', 'bool', function()
    -- Network buffering of a web video stalls playback-time while `pause`
    -- stays false.  Rebase to the frozen timeline and repaint so danmaku do
    -- not keep drifting while the video waits for data.
    if active then
        rebase_vod_clock(active)
        render_vod_overlay()
    end
    update_render_timer()
end)
mp.observe_property('speed', 'number', function()
    if active then rebase_vod_clock(active) end
end)
mp.observe_property('osd-dimensions', 'native', function()
    if active then render_vod_overlay() end
end)
mp.register_event('seek', function()
    if active then
        mp.add_timeout(0, function()
            if active then
                rebase_vod_clock(active)
                render_vod_overlay()
            end
        end)
    end
    update_render_timer()
end)

mp.register_event('start-file', function(event)
    stop_vod()
    local entry_id = event and event.playlist_entry_id or nil
    if not preserve_live_receiver_for_refresh(entry_id) then stop_live() end
    remember_source_context()
    restore_live_refresh_context(entry_id)
    update_live_send_availability()
end)

mp.register_event('file-loaded', function()
    mp.add_timeout(0, function()
        remember_source_context()
        restore_live_refresh_context()
        remove_automatic_bilibili_danmaku()
        apply_settings_to_current()
        update_live_send_availability()
        if live_refresh_context then
            -- Let delayed yt-dlp metadata settle without retaining a stale
            -- room identity across an unrelated later media change.
            live_refresh_context.keep_receiver = false
            live_refresh_context.expires_at = mp.get_time() + 10
        end
    end)
end)

mp.register_event('end-file', function(event)
    stop_vod()
    local entry_id = event and event.playlist_entry_id or nil
    if not preserve_live_receiver_for_refresh(entry_id) then stop_live() end
    live_send_in_progress = false
    mp.set_property_bool('user-data/bilibili_danmaku/available', false)
    mp.set_property('user-data/bilibili_danmaku/source-kind', '')
    mp.set_property_bool('user-data/bilibili_danmaku/live-send-available', false)
    mp.set_property('user-data/bilibili_danmaku/live-send-source', '')
end)

mp.register_event('shutdown', function()
    if heartbeat_timer then heartbeat_timer:kill() end
    stop_vod()
    stop_live()
    source_context = nil
    live_refresh_context = nil
    live_send_in_progress = false
    mp.set_property_bool('user-data/bilibili_danmaku/available', false)
    mp.set_property('user-data/bilibili_danmaku/source-kind', '')
    mp.set_property_bool('user-data/bilibili_danmaku/live-send-available', false)
    mp.set_property('user-data/bilibili_danmaku/live-send-source', '')
    mp.set_property_native('user-data/bilibili_danmaku/heartbeat', {})
end)

mp.observe_property('user-data/web_source/context', 'native', function()
    if mp.get_property_bool('idle-active', false) then return end
    remember_source_context()
    restore_live_refresh_context()
    update_live_send_availability()
    -- ytdl_hook metadata can arrive one scheduler turn after file-loaded.
    -- Re-applying only for the current item makes that fallback start live
    -- danmaku instead of leaving D enabled with no receiver.
    mp.add_timeout(0, function()
        if not mp.get_property_bool('idle-active', false) then apply_settings_to_current() end
    end)
end)

mp.register_script_message('menu-event', menu_event)
mp.register_script_message('send-live-danmaku', send_live_danmaku)
mp.register_script_message('live-refresh-start', capture_live_refresh_context)
mp.register_script_message('live-refresh-loaded', restore_live_after_refresh)
mp.register_script_message('live-refresh-failed', fail_live_refresh)
mp.add_key_binding(nil, 'toggle', toggle)
mp.add_key_binding(nil, 'menu', open_menu)
mp.add_key_binding(nil, 'font-scale-up', function() adjust_font_scale(font_scale_step) end)
mp.add_key_binding(nil, 'font-scale-down', function() adjust_font_scale(-font_scale_step) end)
