-- Bilibili AI 字幕编排脚本：Q 键优先加载 B 站自带 AI 字幕，失败则回落 Whisper。
-- Whisper 本身不被修改：Q/W 在本脚本无法处理时通过 script-message 转发回
-- whisper_realtime。AI 字幕为整段静态 SRT，sub-add 本地缓存文件；W 在 AI
-- 模式下启用懒翻译泵（逐条、按播放位置邻近度优先），双语显示原文/译文。

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local PYTHON = mp.command_native({ 'expand-path', '~~/../python.exe' })
local HELPER = mp.command_native({ 'expand-path', '~~/tools/bilibili_ai_subtitle.py' })
local CURL = 'curl.exe'
local BRIDGE = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/publish_v13/mpv-cookie-bridge.exe' })
local USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36'

local TRACK_TITLE = 'Bilibili AI字幕'
local MIN_TRANSLATE_INTERVAL = 0.8
local TRANSLATE_FAIL_COOLDOWN = 30
local TRANSLATE_TARGET = 'zh-CN'
-- 与 whisper_realtime 相同的翻译端点顺序：gtx 被反爬拦截时回退 Chrome 内置接口。
local TRANSLATE_ENDPOINTS = {
    {
        url = 'https://translate.googleapis.com/translate_a/single',
        params = { 'client=gtx', 'sl=auto', 'tl=zh-CN', 'dt=t' },
    },
    {
        url = 'https://translate.googleapis.com/translate_a/t',
        params = { 'anno=3', 'client=dict-chrome-ex', 'sl=auto', 'tl=zh-CN', 'v=1.0' },
    },
}

local state = {
    mode = nil,                 -- nil | 'ai' | 'whisper'
    loading = false,
    generation = 0,
    track_id = nil,
    srt_path = nil,
    entries = {},               -- {from, to, text, key}
    translation_cache = {},     -- [comparable key] = 译文
    translation_pending = {},   -- [comparable key] = true
    translation_busy = false,
    translation_last_sent = 0,
    translation_retry_after = 0,
    meta = nil,                 -- {lan, lan_doc}
    previous_sub_pos = nil,
    previous_secondary_sub_pos = nil,
}

local function trim(value)
    local text = tostring(value or '')
    text = text:gsub('^%s+', '')
    text = text:gsub('%s+$', '')
    return text
end

local function now_time()
    return mp.get_property_number('playback-time')
end

local function current_track_list()
    local tracks = mp.get_property_native('track-list')
    return type(tracks) == 'table' and tracks or {}
end

local function is_generated_track(track)
    if not track or track.type ~= 'sub' then return false end
    local title = tostring(track.title or '')
    if title:sub(1, #TRACK_TITLE) == TRACK_TITLE then return true end
    -- 本地文件轨的显示标题可能被 mpv 改写为文件名，改按缓存文件路径识别。
    local url = tostring(track['external-filename'] or '')
    if url:find('bilibili_ai_subtitle', 1, true) then return true end
    return false
end

local function remove_generated_tracks()
    for _, track in ipairs(current_track_list()) do
        if is_generated_track(track) and track.id then
            pcall(mp.commandv, 'sub-remove', tostring(track.id))
        end
    end
    state.track_id = nil
end

local function find_new_track(old_id)
    for _, track in ipairs(current_track_list()) do
        if track.type == 'sub' and track.id ~= old_id and is_generated_track(track) then
            return track.id
        end
    end
end

local function track_present(track_id)
    if not track_id then return false end
    for _, track in ipairs(current_track_list()) do
        if track.type == 'sub' and track.id == track_id then return true end
    end
    return false
end

-- 是否有"真正的"主字幕轨（非本脚本生成的轨道）。secondary 依赖主字幕轨存在
-- 才会渲染，因此没有主字幕时生成轨必须直接作为主字幕轨（sid）使用。
local function primary_sub_active()
    for _, track in ipairs(current_track_list()) do
        if track.type == 'sub' and track.selected and not is_generated_track(track) then
            return true
        end
    end
    return false
end

local function format_srt_time(value)
    local millis = math.max(0, math.floor((tonumber(value) or 0) * 1000 + 0.5))
    local hours = math.floor(millis / 3600000)
    millis = millis - hours * 3600000
    local minutes = math.floor(millis / 60000)
    millis = millis - minutes * 60000
    local seconds = math.floor(millis / 1000)
    millis = millis - seconds * 1000
    return string.format('%02d:%02d:%02d,%03d', hours, minutes, seconds, millis)
end

-- 文本比较用归一化：小写、去标点、去空白（与 whisper 一致）。
local function comparable_text(value)
    local text = tostring(value or ''):lower()
    text = text:gsub('%p', '')
    text = text:gsub('%s+', '')
    return text
end

-- 解析 web_source 共享上下文中的 B 站视频 bvid / 分P。
local function parse_bilibili_video()
    local ctx = mp.get_property_native('user-data/web_source/context')
    if type(ctx) ~= 'table' or ctx.kind ~= 'bilibili-video' then return nil, nil end
    local url = tostring(ctx.url or '')
    local bvid = url:match('/video/([Bb][Vv][%w]+)') or url:match('bvid=([Bb][Vv][%w]+)')
    if not bvid then return nil, nil end
    local page = tonumber(url:match('[?&]p=(%d+)')) or 1
    return bvid, page
end

local function write_file(path, content)
    local file = io.open(path, 'wb')
    if not file then return false end
    file:write(content)
    file:close()
    return true
end

local function parse_srt_time(value)
    local hours, minutes, seconds, millis = value:match('(%d+):(%d+):(%d+),(%d+)')
    return (tonumber(hours) or 0) * 3600 + (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
        + (tonumber(millis) or 0) / 1000
end

-- 解析 SRT 为条目表（时间戳使用毫秒 -> 秒），供翻译泵使用。
-- 注意：助手输出的 SRT 是 \r\n 行尾，必须先归一化为 \n 才能按空行分块；
-- 且 match 带两个捕获组时只返回捕获值，两个时间戳要一次性取出。
local function parse_srt(srt)
    srt = tostring(srt or ''):gsub('\r\n', '\n')
    local entries = {}
    for block in (srt .. '\n\n'):gmatch('(.-)\n\n') do
        local from_s, to_s = block:match('(%d+:%d+:%d+,%d+) %-%-> (%d+:%d+:%d+,%d+)')
        if from_s and to_s then
            local text = block:gsub('^%s*%d+%s*\n%s*%d+:%d+:%d+,%d+ %-%-> %d+:%d+:%d+,%d+%s*\n', ''):gsub('^%s+', ''):gsub('%s+$', '')
            if text ~= '' then
                entries[#entries + 1] = {
                    from = parse_srt_time(from_s),
                    to = parse_srt_time(to_s),
                    text = text,
                    key = comparable_text(text),
                }
            end
        end
    end
    return entries
end

-- 把当前条目重建为双语 SRT 文本并写回缓存文件，sub-reload 原位更新轨道。
local function rebuild_and_reload()
    if not state.srt_path then return end
    local rows = {}
    local number = 0
    for _, entry in ipairs(state.entries) do
        number = number + 1
        rows[#rows + 1] = tostring(number)
        rows[#rows + 1] = format_srt_time(entry.from) .. ' --> ' .. format_srt_time(entry.to)
        local line = entry.text
        local translated = state.translation_cache[entry.key]
        if translated and translated ~= '' then line = line .. '\n' .. translated end
        rows[#rows + 1] = line
        rows[#rows + 1] = ''
    end
    local srt = table.concat(rows, '\r\n')
    if not write_file(state.srt_path, srt) then return end
    local track_id = state.track_id
    if not track_id or not track_present(track_id) then return end
    pcall(mp.commandv, 'sub-reload', tostring(track_id))
end

local function configured_proxy()
    local options = mp.get_property_native('options/ytdl-raw-options')
    if type(options) == 'table' then
        if type(options.proxy) == 'string' and options.proxy ~= '' then return options.proxy end
        for _, item in pairs(options) do
            if type(item) == 'string' then
                local proxy = item:match('^%s*proxy=(.+)$')
                if proxy and proxy ~= '' then return proxy end
            end
        end
    end
    if type(options) == 'string' then
        for item in options:gmatch('[^,;]+') do
            local proxy = item:match('^%s*proxy=(.+)$')
            if proxy and proxy ~= '' then return proxy end
        end
    end
    local proxy = mp.get_property('http-proxy')
    return proxy and proxy ~= '' and proxy or nil
end

-- 解析翻译接口响应（与 whisper 相同）：gtx 为多行数组，dict-chrome-ex 为平铺数组。
local function parse_translation(data)
    if type(data) ~= 'table' or type(data[1]) ~= 'table' then return '' end
    if type(data[1][1]) == 'table' then
        local parts = {}
        for _, row in ipairs(data[1]) do
            if type(row) == 'table' and type(row[1]) == 'string' and row[1] ~= '' then
                parts[#parts + 1] = row[1]
            end
        end
        return table.concat(parts)
    end
    local trans = data[1][1]
    if type(trans) == 'string' and trans ~= '' then return trans end
    return ''
end

local function do_translate(key, endpoint_index)
    state.translation_busy = true
    state.translation_last_sent = mp.get_time()
    local endpoint = TRANSLATE_ENDPOINTS[endpoint_index]
    local proxy = configured_proxy()
    local args = { CURL, '--silent', '--show-error', '--fail', '--connect-timeout', '5', '--max-time', '15', '-G' }
    for _, param in ipairs(endpoint.params) do
        args[#args + 1] = '--data-urlencode'
        args[#args + 1] = param
    end
    args[#args + 1] = '--data-urlencode'
    args[#args + 1] = 'q=' .. key
    if proxy then
        args[#args + 1] = '--proxy'
        args[#args + 1] = proxy
    end
    args[#args + 1] = endpoint.url
    mp.command_native_async({
        name = 'subprocess',
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function(success, result, error_message)
        local stdout = result and result.stdout or ''
        if success and result and result.status == 0 then
            local data = utils.parse_json(stdout)
            local translated = parse_translation(data)
            if translated ~= '' then
                state.translation_cache[key] = translated
                state.translation_pending[key] = nil
                state.translation_busy = false
                if state.mode == 'ai' then rebuild_and_reload() end
                return
            end
        end
        if endpoint_index < #TRANSLATE_ENDPOINTS then
            do_translate(key, endpoint_index + 1)
            return
        end
        state.translation_busy = false
        msg.error(string.format('[bilibili_ai_subtitle] translate all endpoints failed: key=%q success=%s status=%s error=%s stdout=%s',
            key, tostring(success), tostring(result and result.status), tostring(error_message),
            trim(stdout):sub(1, 512)))
        state.translation_retry_after = mp.get_time() + TRANSLATE_FAIL_COOLDOWN
    end)
end

-- 翻译泵：单飞行 + 最小间隔 + 失败冷却，按播放位置邻近度优先（最近的最先出译文）。
local function pump_translation()
    if state.mode ~= 'ai' or state.translation_busy then return end
    if mp.get_time() < state.translation_retry_after then return end
    if mp.get_time() - state.translation_last_sent < MIN_TRANSLATE_INTERVAL then return end
    local current = now_time()
    local best_key, best_distance
    for _, entry in ipairs(state.entries) do
        local key = entry.key
        if key and key ~= '' and state.translation_pending[key] and not state.translation_cache[key] then
            local distance = current and math.abs(entry.from - current) or math.huge
            if not best_key or distance < best_distance then
                best_key, best_distance = key, distance
            end
        end
    end
    if best_key then
        state.translation_pending[best_key] = true
        do_translate(best_key, 1)
    end
end

local function translation_tick()
    if state.mode == 'ai' and state.ai_translate then pump_translation() end
end

-- 从助手 stderr 提取 @meta JSON 行。
local function parse_meta(stderr)
    local line = tostring(stderr or ''):match('@meta%s+(%b{})')
    if not line then return nil end
    local data = utils.parse_json(line)
    if type(data) ~= 'table' then return nil end
    return data
end

local function fallback_to_whisper(reason)
    if state.mode ~= nil and state.mode ~= 'whisper' then return end
    state.loading = false
    state.mode = 'whisper'
    local text = '无 B站 AI 字幕' .. (reason and reason ~= '' and '（' .. reason .. '）' or '') .. '，已启动 Whisper 实时字幕'
    mp.osd_message(text, 4)
    msg.info('[bilibili_ai_subtitle] fallback to whisper: ' .. tostring(reason))
    mp.commandv('script-binding', 'whisper_realtime/toggle')
end

-- 轨道不存在时（首次 / seek 后轨道被重置）重建：清旧轨、sub-add、再显式选中。
local function ensure_subtitle_track(srt_path, generation)
    remove_generated_tracks()
    state.track_id = nil
    -- 不带 flags 注入，避免 mpv 自动选中生成轨作为主字幕；选中由下方显式决定。
    local ok, add_error = pcall(mp.commandv, 'sub-add', srt_path, '', TRACK_TITLE)
    if not ok then
        msg.error('[bilibili_ai_subtitle] sub-add failed: ' .. tostring(add_error))
        mp.osd_message('B站 AI字幕轨道注入失败', 3)
        return
    end
    local function select_track(attempt)
        if state.mode ~= 'ai' or generation ~= state.generation then return end
        local new_id = find_new_track(nil)
        if not new_id then
            if attempt < 40 then
                mp.add_timeout(0.05, function() select_track(attempt + 1) end)
            end
            return
        end
        state.track_id = new_id
        if primary_sub_active() then
            pcall(mp.set_property, 'secondary-sid', tostring(new_id))
            pcall(mp.set_property_bool, 'secondary-sub-visibility', true)
            pcall(mp.set_property_bool, 'sub-visibility', true)
        else
            pcall(mp.set_property, 'secondary-sid', 'no')
            pcall(mp.set_property_bool, 'secondary-sub-visibility', false)
            pcall(mp.set_property, 'sid', tostring(new_id))
            pcall(mp.set_property_bool, 'sub-visibility', true)
        end
    end
    select_track(0)
end

local function mount_ai_subtitle(srt, meta, bvid, page)
    if srt == '' then
        fallback_to_whisper('字幕内容为空')
        return
    end
    local cache_dir = mp.command_native({ 'expand-path', '~~/cache' })
    local path = cache_dir .. '/bilibili_ai_subtitle_' .. bvid:gsub('%W', '') .. '_' .. tostring(page) .. '.srt'
    if not write_file(path, srt) then
        fallback_to_whisper('无法写入字幕缓存文件')
        return
    end
    state.loading = false
    state.mode = 'ai'
    state.generation = state.generation + 1
    local generation = state.generation
    state.srt_path = path
    state.meta = meta
    state.entries = parse_srt(srt)
    state.ai_translate = false
    state.translation_cache = {}
    state.translation_pending = {}
    state.translation_busy = false
    state.translation_last_sent = 0
    state.translation_retry_after = 0
    -- 与 Whisper 一致：字幕显示在底部；保存原值，关闭时恢复。
    state.previous_sub_pos = mp.get_property_number('sub-pos', 100)
    state.previous_secondary_sub_pos = mp.get_property_number('secondary-sub-pos', 0)
    pcall(mp.set_property, 'sub-pos', '100')
    pcall(mp.set_property, 'secondary-sub-pos', '100')
    ensure_subtitle_track(path, generation)
    local lan_doc = (type(meta) == 'table' and meta.lan_doc) or ''
    mp.osd_message('B站 AI字幕已开启（' .. lan_doc .. '）', 3)
end

local function fetch_and_mount(bvid, page)
    state.loading = true
    state.generation = state.generation + 1
    local generation = state.generation
    mp.osd_message('正在获取 B站 AI 字幕...', 3)
    local args = { PYTHON, HELPER, '--bvid', bvid, '--page', tostring(page), '--bridge', BRIDGE, '--user-agent', USER_AGENT }
    mp.command_native_async({
        name = 'subprocess',
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 4 * 1024 * 1024,
        playback_only = false,
    }, function(success, result, error_message)
        if generation ~= state.generation then return end
        if success and result and result.status == 0 then
            local srt = result.stdout or ''
            local meta = parse_meta(result.stderr or '')
            mount_ai_subtitle(srt, meta, bvid, page)
            return
        end
        local reason = trim(result and result.stderr or '')
        if reason == '' then
            reason = error_message and tostring(error_message) or '获取失败'
        end
        fallback_to_whisper(reason)
    end)
end

local function cleanup_ai()
    state.generation = state.generation + 1
    state.loading = false
    state.mode = nil
    state.ai_translate = false
    remove_generated_tracks()
    if state.srt_path then
        pcall(os.remove, state.srt_path)
        state.srt_path = nil
    end
    if state.previous_sub_pos ~= nil then
        pcall(mp.set_property, 'sub-pos', tostring(state.previous_sub_pos))
        state.previous_sub_pos = nil
    end
    if state.previous_secondary_sub_pos ~= nil then
        pcall(mp.set_property, 'secondary-sub-pos', tostring(state.previous_secondary_sub_pos))
        state.previous_secondary_sub_pos = nil
    end
    state.meta = nil
    state.entries = {}
end

local function disable_ai()
    cleanup_ai()
    mp.osd_message('B站 AI字幕已关闭', 2)
end

local function toggle()
    if state.mode == 'ai' then
        disable_ai()
        return
    end
    if state.loading then
        -- 获取中再按 Q：取消本次获取。
        state.generation = state.generation + 1
        state.loading = false
        mp.osd_message('已取消获取 B站 AI 字幕', 2)
        return
    end
    if state.mode == 'whisper' then
        state.mode = nil
        mp.commandv('script-binding', 'whisper_realtime/toggle')
        return
    end
    local bvid, page = parse_bilibili_video()
    if not bvid then
        state.mode = 'whisper'
        mp.commandv('script-binding', 'whisper_realtime/toggle')
        return
    end
    fetch_and_mount(bvid, page)
end

local function translate()
    if state.mode == 'ai' then
        if state.ai_translate then
            state.ai_translate = false
            mp.osd_message('B站 AI字幕翻译：已关闭', 2)
            return
        end
        local lan = (type(state.meta) == 'table' and tostring(state.meta.lan or '')):lower()
        if lan:match('^zh') then
            mp.osd_message('B站 AI字幕已是中文，无需翻译', 2)
            return
        end
        state.ai_translate = true
        for _, entry in ipairs(state.entries) do
            local key = entry.key
            if key and key ~= '' and not state.translation_cache[key] then
                state.translation_pending[key] = true
            end
        end
        mp.osd_message('B站 AI字幕翻译：已开启', 2)
        return
    end
    -- 非 AI 模式：转发 Whisper 翻译开关。
    mp.commandv('script-binding', 'whisper_realtime/translate')
end

local function close_on_file_change()
    if state.mode == 'ai' or state.loading then
        cleanup_ai()
    end
end

-- 与 whisper_realtime 相同的注册方式：命名绑定，供 input 配置的 script-binding 触发。
mp.add_key_binding(nil, 'toggle', toggle)
mp.add_key_binding(nil, 'translate', translate)

mp.register_event('file-loaded', close_on_file_change)
mp.register_event('end-file', close_on_file_change)
mp.register_event('shutdown', function() close_on_file_change() end)

mp.add_periodic_timer(0.5, translation_tick)
