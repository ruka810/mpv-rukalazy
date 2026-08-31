local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- Session-only realtime subtitles. Audio, JSON, and subtitle text never use a
-- filesystem path; the Python bridge captures audio and uploads it in memory.
local WHISPER_ROOT = 'E:\\whisper'
local WHISPER_SERVER = WHISPER_ROOT .. '\\whisper-server.exe'
local WHISPER_MODEL = WHISPER_ROOT .. '\\models\\ggml-large-v3-turbo-q5_0.bin'
local CURL = 'curl.exe'
local PYTHON = mp.command_native({'expand-path', '~~/../python.exe'})
local REQUEST_BRIDGE = mp.command_native({'expand-path', '~~/tools/whisper_memory_bridge.py'})

local CHUNK_SECONDS = 6.0
local STEP_SECONDS = 4.0
local PRE_ROLL_SECONDS = 1.0
local KEEP_BEHIND_SECONDS = 30.0
local KEEP_AHEAD_SECONDS = 60.0
local JUMP_THRESHOLD_SECONDS = 2.0
local CAPTURE_SIZE = 2 * 1024 * 1024
local TRACK_PREFIX = 'Whisper realtime'
-- 字幕内容始终上传到同一个固定 token 的 URL，已建立的轨道用 sub-reload 原位更新，
-- 避免每次内容变化都重建轨道（旧方案 add/remove 导致字幕闪烁、出现晚、显示短）。
local SUBTITLE_TOKEN = 'realtime'
local MIN_TRANSLATE_INTERVAL = 0.8      -- 相邻翻译请求最小间隔（秒），限流
local TRANSLATE_FAIL_COOLDOWN = 30      -- 翻译失败后的冷却（秒），避免打爆接口
local TRANSLATE_TARGET = 'zh-CN'        -- 目标语言固定简体中文
-- 依次尝试的翻译端点：首个 `client=gtx` 接口被节点 IP 反爬拦截（返回 HTML "Sorry"）时，
-- 自动回退到 Chrome 内置翻译接口 `client=dict-chrome-ex`（同样为 Google 官方网页端）。
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
    enabled = false,
    server_state = 'stopped',
    server_job = nil,
    server_pid = nil,
    probe_job = nil,
    bridge_state = 'stopped',
    bridge_job = nil,
    bridge_pid = nil,
    bridge_probe_job = nil,
    bridge_port = nil,
    capture_job = nil,
    request_job = nil,
    subtitle_upload_job = nil,
    active_request_id = nil,
    request_serial = 0,
    generation = 0,
    file_generation = 0,
    busy = false,
    next_start = nil,
    last_time = nil,
    paused = false,
    buffering = false,
    buffering_since = nil,
    pause_since = nil,
    events = {},
    track_id = nil,
    refresh_serial = 0,
    refresh_token = 0,
    last_srt = nil,
    previous_secondary_sid = nil,
    previous_secondary_visibility = true,
    previous_secondary_pos = nil,
    error_shown = false,
    retry_after = 0,
    port = nil,
    seek_hold_until = 0,
    web_refresh_needed = false,
    last_audio_fallback_key = nil,
    web_context_key = nil,
    translate_enabled = false,
    translation_cache = {},        -- [normalized原文] = 译文   （相同原文复用）
    translation_pending = {},      -- [原文]=true 已入队/在飞/失败不再自动重试
    translation_queue = {},        -- FIFO 待翻译 key 列表
    translation_busy = false,      -- 是否有请求在飞（限流）
    translation_last_sent = 0,
    translation_retry_after = 0,
}

local function file_exists(path)
    return path and utils.file_info(path) ~= nil
end

local function trim(value)
    local text = tostring(value or '')
    text = text:gsub('^%s+', '')
    text = text:gsub('%s+$', '')
    return text
end

local function now_time()
    return mp.get_property_number('playback-time')
end

local function format_seconds(value)
    return string.format('%.3f', math.max(0, tonumber(value) or 0))
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

local function cancel_job(field)
    local id = state[field]
    state[field] = nil
    if id then pcall(mp.abort_async_command, id) end
end

local cancel_bridge_request
local show_error_once

local function cancel_audio_jobs()
    if state.active_request_id and cancel_bridge_request then
        cancel_bridge_request(state.active_request_id)
    end
    state.active_request_id = nil
    cancel_job('capture_job')
    cancel_job('request_job')
    cancel_job('subtitle_upload_job')
    state.busy = false
end

local function kill_server_pid(pid)
    if not pid then return end
    pcall(mp.command_native, {
        name = 'subprocess',
        args = {'taskkill.exe', '/PID', tostring(pid), '/T', '/F'},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    })
end

local function current_track_list()
    local tracks = mp.get_property_native('track-list')
    return type(tracks) == 'table' and tracks or {}
end

local function is_generated_track(track)
    return track and track.type == 'sub'
        and tostring(track.title or ''):sub(1, #TRACK_PREFIX) == TRACK_PREFIX
end

local function remove_generated_tracks()
    for _, track in ipairs(current_track_list()) do
        if is_generated_track(track) and track.id then
            pcall(mp.commandv, 'sub-remove', tostring(track.id))
        end
    end
    state.track_id = nil
end

local function clear_events()
    state.events = {}
    state.last_srt = nil
end

local function normalize_text(value)
    return trim(value):gsub('[\r\n]+', ' '):gsub('%s+', ' ')
end

-- 文本比较用归一化：小写、去标点、去空白。同一句在相邻块里被两次识别时，
-- Whisper 的文本常带标点或前后缀差异（例如一块截成 "ちょっと待って、今行"，
-- 另一块识别成 "待って、今行くよ"），去掉噪声后才能正确归并为同一句。
local function comparable_text(value)
    local text = tostring(value or ''):lower()
    text = text:gsub('%p', '')
    text = text:gsub('%s+', '')
    return text
end

-- 近似文本匹配：一方归一化后是另一方的子串（整句/片段重复）即视为同一句。
local function text_similar(one, other)
    if one == other then return true end
    if #one == 0 or #other == 0 then return false end
    local short, long = one, other
    if #short > #long then short, long = long, short end
    return long:find(short, 1, true) ~= nil
end

local function add_segment(segment, absolute_start)
    local text = normalize_text(segment.text)
    local relative_start = tonumber(segment.start)
    local relative_end = tonumber(segment['end'])
    if text == '' or not relative_start or not relative_end then return end

    local start_time = absolute_start + relative_start
    local end_time = absolute_start + relative_end
    if end_time <= start_time + 0.03 then return end

    local comparable = comparable_text(text)
    if comparable == '' then return end

    for index, old in ipairs(state.events) do
        local overlap = math.min(end_time, old.finish) - math.max(start_time, old.start)
        local same_text = comparable == old.comparable
        -- 同一句原文在相邻重叠块里被重复识别（两次时间戳因模型上下文偏移）。
        -- 完全同文本：重叠或紧邻都视为重复——若新片段显著扩展了时间覆盖则合并，
        -- 否则直接丢弃（覆盖 Whisper 在块尾静音处重复上一句的“拖尾”现象）。
        -- 合并时保持已建立的开始时间不变、只延伸结束时间：先加入的事件来自更早的块、
        -- 位于句子中段，时间戳更可靠；不让后加入块的时间戳把字幕起点拉得更早。
        if same_text and (overlap > 0.05 or (start_time <= old.finish + 0.8 and end_time >= old.start - 0.8)) then
            if end_time > old.finish + 0.15 or start_time < old.start - 0.15 then
                local merged_text = text
                if #old.text > #text then merged_text = old.text end
                state.events[index] = {
                    start = old.start,
                    finish = math.max(end_time, old.finish),
                    text = merged_text, normalized = merged_text, comparable = old.comparable,
                }
            end
            return
        end
        -- 近似文本（一方是另一方的片段/前后缀）：显著重叠时合并为一条。
        if overlap > 0.15 and text_similar(comparable, old.comparable) then
            local merged_text = text
            if #old.text > #text then merged_text = old.text end
            state.events[index] = {
                start = old.start,
                finish = math.max(end_time, old.finish),
                text = merged_text, normalized = merged_text, comparable = old.comparable,
            }
            return
        end
    end

    state.events[#state.events + 1] = {
        start = start_time, finish = end_time, text = text, normalized = text,
        comparable = comparable,
    }
end

local function prune_events(reference_time)
    local kept = {}
    local lower = reference_time - KEEP_BEHIND_SECONDS
    local upper = reference_time + KEEP_AHEAD_SECONDS
    for _, event in ipairs(state.events) do
        if event.finish >= lower and event.start <= upper then kept[#kept + 1] = event end
    end
    table.sort(kept, function(a, b) return a.start < b.start end)
    state.events = kept
end

-- 双语字幕：开启翻译且命中缓存时显示「原文\n译文」，否则仅原文。
local function subtitle_text(event)
    if state.translate_enabled then
        local tr = state.translation_cache[event.normalized]
        if tr and tr ~= '' then return event.text .. '\n' .. tr end
    end
    return event.text
end

local function build_srt(reference_time)
    local rows = {}
    local number = 0
    local lower = reference_time - KEEP_BEHIND_SECONDS
    local upper = reference_time + KEEP_AHEAD_SECONDS
    for _, event in ipairs(state.events) do
        if event.finish >= lower and event.start <= upper then
            number = number + 1
            rows[#rows + 1] = tostring(number)
            rows[#rows + 1] = format_srt_time(event.start) .. ' --> ' .. format_srt_time(event.finish)
            rows[#rows + 1] = subtitle_text(event)
            rows[#rows + 1] = ''
        end
    end
    return table.concat(rows, '\r\n')
end

local function find_new_track(title, old_id)
    for _, track in ipairs(current_track_list()) do
        if track.type == 'sub' and track.title == title and track.id ~= old_id then
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

local function bridge_url(path)
    if not state.bridge_port then return nil end
    return 'http://127.0.0.1:' .. tostring(state.bridge_port) .. path
end

local function clear_remote_subtitles()
    local endpoint = bridge_url('/subtitle')
    if not endpoint then return end
    pcall(mp.command_native_async, {
        name = 'subprocess',
        args = {CURL, '--silent', '--show-error', '--max-time', '2', '--request', 'DELETE', endpoint},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function() end)
end

-- 轨道不存在时（首次启动 / seek / 重置后）才重建：清理旧轨道、sub-add、再选中。
local function ensure_subtitle_track(subtitle_url, refresh_token)
    remove_generated_tracks()
    state.track_id = nil
    local ok, add_error = pcall(mp.commandv, 'sub-add', subtitle_url, 'auto', TRACK_PREFIX)
    if not ok then
        state.last_srt = nil
        msg.error('[whisper_realtime] sub-add failed: ' .. tostring(add_error))
        show_error_once('实时字幕轨道注入失败')
        return
    end
    local function select_track(attempt)
        if not state.enabled or refresh_token ~= state.refresh_token then return end
        local new_id = find_new_track(TRACK_PREFIX, nil)
        if not new_id then
            if attempt < 40 then
                mp.add_timeout(0.05, function() select_track(attempt + 1) end)
            end
            return
        end
        state.track_id = new_id
        pcall(mp.set_property_number, 'secondary-sid', new_id)
        pcall(mp.set_property_bool, 'secondary-sub-visibility', true)
    end
    select_track(0)
end

local function refresh_track(reference_time)
    if not state.enabled then return end
    prune_events(reference_time)
    local srt = build_srt(reference_time)
    if srt == state.last_srt then return end
    state.last_srt = srt

    if srt == '' then
        remove_generated_tracks()
        clear_remote_subtitles()
        return
    end

    state.refresh_token = state.refresh_token + 1
    local refresh_token = state.refresh_token
    local endpoint = bridge_url('/subtitle')
    if not endpoint then
        state.last_srt = nil
        msg.error('[whisper_realtime] subtitle bridge is not ready')
        return
    end

    -- 固定 token：内容总是落在同一个 URL 上，已有轨道可原位 sub-reload 更新。
    local upload_payload = utils.format_json({content = srt, token = SUBTITLE_TOKEN})
    local job_id
    job_id = mp.command_native_async({
        name = 'subprocess',
        args = {CURL, '--silent', '--show-error', '--fail', '--connect-timeout', '2', '--max-time', '8',
            '--request', 'POST', '--header', 'Content-Type: application/json',
            '--data-binary', upload_payload, endpoint},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = CAPTURE_SIZE,
        playback_only = false,
    }, function(success, result, error_message)
        if state.subtitle_upload_job == job_id then state.subtitle_upload_job = nil end
        if not state.enabled or refresh_token ~= state.refresh_token then return end
        if not success or not result or result.status ~= 0 then
            state.last_srt = nil
            msg.error(string.format('[whisper_realtime] subtitle upload failed: success=%s status=%s error=%s stderr=%s',
                tostring(success), tostring(result and result.status), tostring(error_message),
                trim(result and result.stderr or '')))
            show_error_once('实时字幕轨道注入失败')
            return
        end
        local response = utils.parse_json(result.stdout or '')
        local subtitle_url = type(response) == 'table' and trim(response.url) or ''
        if subtitle_url == '' then
            state.last_srt = nil
            msg.error('[whisper_realtime] subtitle bridge returned no URL: '
                .. trim(result.stdout or ''):sub(1, 512))
            show_error_once('实时字幕轨道注入失败')
            return
        end

        -- 已有轨道：原位 reload，避免重建轨道造成的闪烁 / 延迟 / 显示被截断。
        local track_id = state.track_id
        if not track_id or not track_present(track_id) then
            ensure_subtitle_track(subtitle_url, refresh_token)
            return
        end
        local ok_reload = pcall(mp.commandv, 'sub-reload', tostring(track_id))
        if not ok_reload then
            ensure_subtitle_track(subtitle_url, refresh_token)
        end
    end)
    state.subtitle_upload_job = job_id
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

-- 解析翻译接口响应，返回拼接后的译文；非法返回空串。
-- gtx 格式：data[1] 是多个 [译文,原文,...] 行的数组。
-- dict-chrome-ex 格式：data[1] = [译文, 语言] 平铺数组。
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

-- 按顺序尝试端点翻译 key；endpoint_index 为其下标（从 1 起）。
-- 单个端点返回无法解析的响应（如被反爬返回 HTML）时，自动切换下一个端点。
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
                if state.enabled and state.translate_enabled then
                    refresh_track(now_time() or 0)
                end
                return
            end
        end
        -- 当前端点失败（进程错误 / 非零退出 / 返回不可解析响应）。若还有端点则回退。
        if endpoint_index < #TRANSLATE_ENDPOINTS then
            do_translate(key, endpoint_index + 1)
            return
        end
        state.translation_busy = false
        msg.error(string.format('[whisper_realtime] translate all endpoints failed: key=%q success=%s status=%s error=%s stdout=%s',
            key, tostring(success), tostring(result and result.status), tostring(error_message),
            trim(stdout):sub(1, 512)))
        -- 全部端点点失败只进入冷却，不停止 Whisper，也不反复重试同一句。
        state.translation_retry_after = mp.get_time() + TRANSLATE_FAIL_COOLDOWN
    end)
end

local function translate_text(key)
    if not key or key == '' or state.translation_cache[key] then return end
    state.translation_pending[key] = true
    do_translate(key, 1)
end

-- 收集当前 events 中尚未翻译（不在缓存、未在 pending）的原文并入队。
local function queue_missing_translations()
    if not state.translate_enabled then return end
    for _, event in ipairs(state.events) do
        local key = event.normalized
        if key and key ~= '' and not state.translation_cache[key]
            and not state.translation_pending[key] then
            state.translation_pending[key] = true
            state.translation_queue[#state.translation_queue + 1] = key
        end
    end
end

-- 驱动翻译队列：单飞行 + 最小间隔 + 失败冷却 + FIFO。
local function pump_translation()
    if not state.translate_enabled or state.translation_busy then return end
    if mp.get_time() < state.translation_retry_after then return end
    if mp.get_time() - state.translation_last_sent < MIN_TRANSLATE_INTERVAL then return end
    local key = table.remove(state.translation_queue, 1)
    if key then translate_text(key) end
end

local function toggle_translate()
    if not state.enabled then
        -- Q 关闭时可切换开关但无实际效果（W 不能代替 Q 启动 Whisper）。
        state.translate_enabled = not state.translate_enabled
        mp.osd_message(state.translate_enabled and '实时翻译已开启（待 Whisper 启动）' or '实时翻译已关闭', 2)
        return
    end
    state.translate_enabled = not state.translate_enabled
    if state.translate_enabled then
        queue_missing_translations()
        mp.osd_message('实时翻译已开启', 2)
    else
        state.translation_queue = {}
        mp.osd_message('实时翻译已关闭', 2)
    end
    refresh_track(now_time() or 0)
end

local function web_context()
    local context = mp.get_property_native('user-data/web_source/context')
    if type(context) ~= 'table' then return nil end
    if type(context.url) ~= 'string' or context.url == '' then return nil end
    if type(context.kind) ~= 'string' or context.kind == '' then return nil end
    return context
end

local function web_context_key(context)
    if type(context) ~= 'table' then return '' end
    return tostring(context.url or '') .. '|' .. tostring(context.kind or '')
        .. '|' .. tostring(context.generation or '')
end

local function cache_duration()
    local cache_state = mp.get_property_native('demuxer-cache-state')
    local duration = type(cache_state) == 'table' and tonumber(cache_state['cache-duration']) or nil
    -- Cache duration is the distance from playback-time to the demuxer's live
    -- edge.  Clamp malformed/huge values so a broken stream never schedules
    -- subtitles minutes ahead of playback.
    return math.min(60, math.max(0, duration or 0))
end

local function source_info()
    local source = mp.get_property('stream-open-filename')
    if not source or source == '' then source = mp.get_property('path') end
    if not source or source == '' then return nil end

    local aid = mp.get_property_number('aid', 0)
    local ff_index = nil
    local audio = {id = aid, lang = '', title = '', channels = ''}
    for _, track in ipairs(current_track_list()) do
        if track.type == 'audio' and track.id == aid then
            ff_index = track['ff-index'] or track.ff_index
            audio.lang = track.lang or track.language or ''
            audio.title = track.title or ''
            audio.channels = track['audio-channels'] or track.audio_channels or ''
            break
        end
    end
    local context = web_context()
    return {
        -- A web request is always re-resolved from its page URL.  mpv can
        -- expose an EDL string or an expiring signed URL here after ytdl_hook.
        path = context and context.url or source,
        map = ff_index and ('0:' .. tostring(ff_index)) or '0:a:0',
        seekable = mp.get_property_bool('seekable', true),
        audio = audio,
        page_url = context and context.url or nil,
        web_kind = context and context.kind or nil,
        context_key = web_context_key(context),
        -- The configured proxy belongs to yt-dlp webpage resolution.  A local
        -- file or direct media URL must not receive it through the bridge.
        proxy = context and configured_proxy() or nil,
    }
end

cancel_bridge_request = function(request_id)
    if not request_id or not state.bridge_port then return end
    local payload = utils.format_json({request_id = request_id})
    pcall(mp.command_native_async, {
        name = 'subprocess',
        args = {CURL, '--silent', '--show-error', '--max-time', '2', '--request', 'POST',
            '--header', 'Content-Type: application/json', '--data-binary', payload,
            'http://127.0.0.1:' .. tostring(state.bridge_port) .. '/cancel'},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function() end)
end

local function request_args(info, start_time, request_id)
    local payload = {
        endpoint = 'http://127.0.0.1:' .. tostring(state.port) .. '/inference',
        request_id = request_id,
        source = info.path,
        map = info.map,
        start = tonumber(format_seconds(start_time)),
        duration = CHUNK_SECONDS,
        seekable = info.seekable,
        page_url = info.page_url,
        web_kind = info.web_kind,
        audio = info.audio,
        proxy = info.proxy,
        file_generation = state.file_generation,
        context_key = info.context_key,
        refresh_web = state.web_refresh_needed and info.page_url ~= nil and info.web_kind ~= nil or false,
    }
    return {
        CURL, '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '180',
        '--request', 'POST', '--header', 'Content-Type: application/json',
        '--data-binary', utils.format_json(payload),
        'http://127.0.0.1:' .. tostring(state.bridge_port) .. '/transcribe',
    }
end

show_error_once = function(text)
    if state.error_shown then return end
    state.error_shown = true
    mp.osd_message(text, 4)
end

local function bridge_error_message(info, stage)
    if stage == 'resolve' then
        return info.page_url and '网页音频解析失败，不影响播放' or '音频源解析失败'
    end
    if stage == 'capture' then
        return info.page_url and '网页音频采集失败，不影响播放' or 'Whisper 音频采集失败'
    end
    if stage == 'whisper' then return 'Whisper CUDA 识别失败' end
    if stage == 'subtitle' then return '实时字幕轨道注入失败' end
    return info.page_url and '网页音频识别失败，不影响播放' or 'Whisper 识别请求失败'
end

local function request_is_current(info, file_generation)
    if state.file_generation ~= file_generation then return false end
    if info.context_key ~= '' and web_context_key(web_context()) ~= info.context_key then return false end
    return mp.get_property_number('aid', 0) == tonumber(info.audio and info.audio.id or 0)
end

local function send_audio(token, subtitle_start, live_anchor, info, actual_start)
    if token ~= state.generation or not state.enabled then return end
    state.request_serial = state.request_serial + 1
    local request_id = tostring(token) .. '-' .. tostring(state.request_serial)
    local request_file_generation = state.file_generation
    state.active_request_id = request_id
    local job_id
    job_id = mp.command_native_async({
        name = 'subprocess',
        args = request_args(info, actual_start, request_id),
        capture_stdout = true,
        capture_stderr = true,
        capture_size = CAPTURE_SIZE,
        playback_only = false,
    }, function(success, result, error_message)
        if state.request_job == job_id then state.request_job = nil end
        if state.active_request_id == request_id then state.active_request_id = nil end
        if token ~= state.generation or not state.enabled or not request_is_current(info, request_file_generation) then return end
        if not success or not result or result.status ~= 0 then
            msg.error(string.format('[whisper_realtime] request failed: success=%s status=%s error=%s stderr=%s',
                tostring(success), tostring(result and result.status), tostring(error_message),
                trim(result and result.stderr or '')))
            show_error_once('Whisper 识别请求失败')
            state.busy = false
            state.retry_after = mp.get_time() + 1.5
            return
        end
        local response = utils.parse_json(result.stdout or '')
        if type(response) == 'table' and response.ok == false then
            local detail = trim(response.error or '桥接服务返回错误')
            local stage = trim(response.stage or 'bridge')
            msg.error('[whisper_realtime] bridge ' .. stage .. ' error: ' .. detail)
            show_error_once(bridge_error_message(info, stage))
            state.busy = false
            state.retry_after = mp.get_time() + 1.5
            return
        end
        if type(response) ~= 'table' or type(response.segments) ~= 'table' then
            msg.error('[whisper_realtime] invalid whisper response: '
                .. trim(result.stdout or ''):sub(1, 512))
            show_error_once('Whisper 返回中没有时间戳片段')
            state.busy = false
            state.retry_after = mp.get_time() + 1.5
            return
        end
        state.error_shown = false
        state.retry_after = 0
        local is_live = response.is_live == true
        local event_origin = subtitle_start
        if is_live then
            -- `live_anchor` points at mpv's cached live edge when the request
            -- was sent.  The bridge reports its own resolve/capture delay so
            -- newly opened HLS/FLV readers map back onto mpv's timeline.
            event_origin = live_anchor + math.max(0, tonumber(response.capture_started_after)
                or tonumber(response.capture_offset) or 0)
        elseif not info.seekable then
            event_origin = event_origin + math.max(0, tonumber(response.capture_offset) or 0)
        end
        if response.audio_selection == 'fallback' then
            local fallback_key = tostring(info.page_url or '') .. '|' .. tostring(info.audio and info.audio.lang or '')
            if state.last_audio_fallback_key ~= fallback_key then
                state.last_audio_fallback_key = fallback_key
                mp.osd_message('网页音轨未匹配，Whisper 使用最佳可用音频', 4)
            end
        end
        for _, segment in ipairs(response.segments) do add_segment(segment, event_origin) end
        local current = now_time() or event_origin
        refresh_track(current)
        state.next_start = is_live and ((now_time() or actual_start) + STEP_SECONDS)
            or (event_origin + STEP_SECONDS)
        if info.page_url and info.web_kind then state.web_refresh_needed = false end
        state.busy = false
    end)
    state.request_job = job_id
end

local function capture_chunk(token, chunk_start)
    local info = source_info()
    if not info then
        state.busy = false
        show_error_once('当前媒体没有可用音频源')
        return
    end

    local current = now_time() or chunk_start
    local actual_start = info.seekable and chunk_start or current
    local subtitle_start = info.seekable and chunk_start or actual_start
    local live_anchor = current + cache_duration()
    send_audio(token, subtitle_start, live_anchor, info, actual_start)
end

local function probe_server()
    if state.server_state ~= 'starting' or state.probe_job then return end
    state.probe_job = mp.command_native_async({
        name = 'subprocess',
        args = {CURL, '--silent', '--show-error', '--fail', '--max-time', '1',
            'http://127.0.0.1:' .. tostring(state.port) .. '/'},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function(success, result)
        state.probe_job = nil
        if not state.enabled or state.server_state ~= 'starting' then return end
        if success and result and result.status == 0 then
            state.server_state = 'ready'
            state.error_shown = false
            local current = now_time()
            if current then
                state.next_start = math.max(0, current - PRE_ROLL_SECONDS)
                state.last_time = current
            end
            mp.osd_message('实时字幕已开启', 2)
        end
    end)
end

local function probe_bridge()
    if state.bridge_state ~= 'starting' or state.bridge_probe_job then return end
    state.bridge_probe_job = mp.command_native_async({
        name = 'subprocess',
        args = {CURL, '--silent', '--show-error', '--fail', '--max-time', '1',
            'http://127.0.0.1:' .. tostring(state.bridge_port) .. '/health'},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function(success, result)
        state.bridge_probe_job = nil
        if not state.enabled or state.bridge_state ~= 'starting' then return end
        if success and result and result.status == 0 then
            state.bridge_state = 'ready'
        end
    end)
end

local function powershell_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function start_bridge()
    state.bridge_port = 18800 + math.random(0, 799)
    state.bridge_state = 'launching'
    local token = state.generation
    local bridge_args = {REQUEST_BRIDGE, '--serve', '--port', tostring(state.bridge_port)}
    local quoted_args = {}
    for _, value in ipairs(bridge_args) do quoted_args[#quoted_args + 1] = powershell_quote(value) end
    local command = '$p = Start-Process -FilePath ' .. powershell_quote(PYTHON)
        .. ' -ArgumentList @(' .. table.concat(quoted_args, ',')
        .. ') -WindowStyle Hidden -PassThru; [Console]::Out.Write($p.Id)'
    state.bridge_job = mp.command_native_async({
        name = 'subprocess',
        args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', command},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function(success, result)
        state.bridge_job = nil
        local pid = result and tonumber(trim(result.stdout)) or nil
        if token ~= state.generation or not state.enabled then
            kill_server_pid(pid)
            return
        end
        if success and result and result.status == 0 and pid then
            state.bridge_pid = pid
            state.bridge_state = 'starting'
        else
            state.bridge_state = 'stopped'
            show_error_once('Whisper 内存桥接服务无法启动')
        end
    end)
end

local function start_server()
    -- 18000-18799 落在 Windows 系统端口排除区间（见 netsh excludedportrange），bind 会失败；
    -- 改用 20000-20799 安全区间，避免 whisper-server 启动即退出的问题。
    state.port = 20000 + math.random(0, 799)
    state.server_state = 'launching'
    local token = state.generation
    local server_args = {
        '-m', WHISPER_MODEL,
        '--host', '127.0.0.1',
        '--port', tostring(state.port),
        '-l', 'auto',
    }
    local quoted_args = {}
    for _, value in ipairs(server_args) do quoted_args[#quoted_args + 1] = powershell_quote(value) end
    local command = '$p = Start-Process -FilePath ' .. powershell_quote(WHISPER_SERVER)
        .. ' -ArgumentList @(' .. table.concat(quoted_args, ',')
        .. ') -WindowStyle Hidden -PassThru; [Console]::Out.Write($p.Id)'
    state.server_job = mp.command_native_async({
        name = 'subprocess',
        args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', command},
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024,
        playback_only = false,
    }, function(success, result, error_message)
        state.server_job = nil
        local pid = result and tonumber(trim(result.stdout)) or nil
        if token ~= state.generation or not state.enabled then
            kill_server_pid(pid)
            return
        end
        if success and result and result.status == 0 and pid then
            state.server_pid = pid
            state.server_state = 'starting'
        else
            state.server_state = 'stopped'
            show_error_once('Whisper CUDA 服务无法启动')
        end
    end)
end

local function reset_timeline(reason, clear_track, refresh_web)
    state.generation = state.generation + 1
    cancel_audio_jobs()
    clear_events()
    if clear_track then
        state.refresh_token = state.refresh_token + 1
        remove_generated_tracks()
    end
    local current = now_time()
    state.last_time = current
    state.next_start = current and math.max(0, current - PRE_ROLL_SECONDS) or nil
    state.retry_after = 0
    state.last_audio_fallback_key = nil
    if refresh_web and web_context() then state.web_refresh_needed = true end
    if reason then msg.debug('[whisper_realtime] timeline reset: ' .. reason) end
end

local function restore_secondary_track_state()
    if state.previous_secondary_sid then
        pcall(mp.set_property, 'secondary-sid', state.previous_secondary_sid)
    end
    pcall(mp.set_property_bool, 'secondary-sub-visibility', state.previous_secondary_visibility)
    if state.previous_secondary_pos ~= nil then
        pcall(mp.set_property, 'secondary-sub-pos', tostring(state.previous_secondary_pos))
    end
end

local function stop_server()
    cancel_job('probe_job')
    cancel_job('server_job')
    kill_server_pid(state.server_pid)
    state.server_pid = nil
    state.server_state = 'stopped'
    state.port = nil
end

local function stop_bridge()
    cancel_job('bridge_probe_job')
    cancel_job('bridge_job')
    kill_server_pid(state.bridge_pid)
    state.bridge_pid = nil
    state.bridge_state = 'stopped'
    state.bridge_port = nil
end

local function disable()
    if not state.enabled then return end
    state.enabled = false
    state.generation = state.generation + 1
    cancel_audio_jobs()
    clear_remote_subtitles()
    stop_server()
    stop_bridge()
    state.refresh_token = state.refresh_token + 1
    remove_generated_tracks()
    clear_events()
    restore_secondary_track_state()
    state.previous_secondary_sid = nil
    state.previous_secondary_pos = nil
    state.last_time = nil
    state.next_start = nil
    state.seek_hold_until = 0
    state.web_refresh_needed = false
    state.web_context_key = nil
    mp.osd_message('实时字幕已关闭', 2)
end

local function enable()
    if state.enabled then return end
    if not file_exists(WHISPER_SERVER) or not file_exists(WHISPER_MODEL)
        or not file_exists(PYTHON) or not file_exists(REQUEST_BRIDGE) then
        mp.osd_message('找不到 E:\\whisper 的 Whisper CUDA 文件', 4)
        return
    end
    if not file_exists('C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe') and not file_exists('C:\\Windows\\System32\\ffmpeg.exe') then
        -- PATH may still provide ffmpeg; the first capture will report a clear error.
        msg.warn('[whisper_realtime] ffmpeg was not found at the common Windows paths')
    end

    state.enabled = true
    state.error_shown = false
    state.previous_secondary_sid = mp.get_property('secondary-sid')
    state.previous_secondary_visibility = mp.get_property_bool('secondary-sub-visibility', true)
    state.previous_secondary_pos = mp.get_property_number('secondary-sub-pos', 0)
    -- The generated SRT lives on the secondary subtitle track.  Give it a
    -- stable bottom placement for this session and restore the user's value
    -- when Q is turned off.
    pcall(mp.set_property, 'secondary-sub-pos', '100')
    reset_timeline('enable', true, true)
    start_bridge()
    start_server()
    mp.osd_message('正在启动 Whisper CUDA 实时字幕...', 3)
end

local function toggle()
    local ok, error_message = xpcall(function()
        if state.enabled then disable() else enable() end
    end, debug.traceback)
    if not ok then
        msg.error('[whisper_realtime] toggle failed: ' .. tostring(error_message))
        pcall(mp.set_property, 'user-data/whisper_realtime/last-error', tostring(error_message))
        mp.osd_message('实时字幕切换失败，详见控制台', 4)
    end
end

local function on_playback_time(_, value)
    if not state.enabled or type(value) ~= 'number' then return end
    if state.last_time and math.abs(value - state.last_time) > JUMP_THRESHOLD_SECONDS then
        reset_timeline('playback jump', true, true)
        state.seek_hold_until = mp.get_time() + 0.3
    else
        state.last_time = value
    end
end

local function on_pause(_, value)
    local paused = value == true
    if paused and not state.paused then state.pause_since = os.clock() end
    if not paused and state.paused and state.pause_since and os.clock() - state.pause_since > JUMP_THRESHOLD_SECONDS then
        reset_timeline('long pause resume', true, true)
    end
    state.paused = paused
    if not paused then state.pause_since = nil end
end

local function on_buffering(_, value)
    local buffering = value == true
    if buffering and not state.buffering then state.buffering_since = os.clock() end
    if not buffering and state.buffering and state.buffering_since
        and os.clock() - state.buffering_since > 0.75 then
        reset_timeline('cache resume', true, true)
    end
    state.buffering = buffering
    if not buffering then state.buffering_since = nil end
end

local function on_cache_buffering(_, value)
    if type(value) == 'number' and value < 100 then
        on_buffering(nil, true)
    elseif type(value) == 'number' then
        on_buffering(nil, false)
    end
end

local function on_seek()
    if state.enabled then
        -- Subtitle work is invalidated only.  It never sends an mpv seek or
        -- touches cache/pause state, so the user's exact seek remains intact.
        reset_timeline('seek event', true, true)
        state.seek_hold_until = mp.get_time() + 0.3
    end
end

local function on_file_loaded()
    if state.enabled then reset_timeline('new file', true, true) end
end

local function on_start_file()
    state.file_generation = state.file_generation + 1
    if state.enabled then reset_timeline('start file', true, true) end
end

local function on_end_file()
    if state.enabled then reset_timeline('end file', true, true) end
end

local function on_audio_track_change()
    if state.enabled then reset_timeline('audio track changed', true, true) end
end

local function on_web_context(_, context)
    local key = web_context_key(context)
    if key == state.web_context_key then return end
    state.web_context_key = key
    if state.enabled then reset_timeline('web source context changed', true, true) end
end

local function tick()
    if not state.enabled then return end
    if state.translate_enabled then
        queue_missing_translations()
        pump_translation()
    end
    if state.bridge_state == 'starting' then probe_bridge() end
    if state.server_state == 'starting' then
        probe_server()
    end
    if state.bridge_state == 'launching' or state.server_state == 'launching' then return end
    if state.bridge_state ~= 'ready' or state.server_state ~= 'ready' then return end
    if state.busy or state.paused or state.buffering then return end
    if mp.get_time() < state.retry_after then return end
    if mp.get_time() < state.seek_hold_until then return end

    local current = now_time()
    if not current then return end
    if not state.next_start then state.next_start = math.max(0, current - PRE_ROLL_SECONDS) end
    if current - state.next_start > STEP_SECONDS * 1.5 then
        state.next_start = math.max(0, current - PRE_ROLL_SECONDS)
    end

    local chunk_start = state.next_start
    state.busy = true
    local token = state.generation
    capture_chunk(token, chunk_start)
end

math.randomseed(os.time() + math.floor((mp.get_time() or 0) * 1000))
mp.add_key_binding(nil, 'toggle', toggle)
mp.add_key_binding(nil, 'translate', toggle_translate)
mp.observe_property('playback-time', 'number', on_playback_time)
mp.observe_property('pause', 'bool', on_pause)
mp.observe_property('paused-for-cache', 'bool', on_buffering)
mp.observe_property('cache-buffering-state', 'number', on_cache_buffering)
mp.observe_property('aid', 'number', on_audio_track_change)
mp.observe_property('user-data/web_source/context', 'native', on_web_context)
mp.register_event('seek', on_seek)
mp.register_event('start-file', on_start_file)
mp.register_event('file-loaded', on_file_loaded)
mp.register_event('end-file', on_end_file)
mp.register_event('shutdown', disable)
mp.add_periodic_timer(0.25, tick)
