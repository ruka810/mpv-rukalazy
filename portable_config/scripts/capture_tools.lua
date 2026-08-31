local msg = require 'mp.msg'

local save_dialog = mp.command_native({'expand-path', '~~/tools/select_save_path.ps1'})
local ffmpeg = 'ffmpeg'
local clip_start = nil
local clip_source = nil

local image_extensions = {png = true, jpg = true, jpeg = true, webp = true}
local video_extensions = {mkv = true, mp4 = true, webm = true, mov = true}
local text_subtitle_codecs = {
    ass = true, ssa = true, subrip = true, srt = true, webvtt = true, vtt = true,
    mov_text = true, text = true, ttml = true, sami = true, microdvd = true,
    jacosub = true, mpl2 = true, pjs = true, realtext = true,
}

local function trim(value)
    return (value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function file_extension(path)
    return (path and path:match('%.([^%.]+)$') or ''):lower()
end

local function replace_extension(path, extension)
    return (path:gsub('%.([^%.]+)$', '') .. '.' .. extension)
end

local function basename(path)
    return (path or ''):match('([^\\/]+)$') or path or ''
end

local function is_local_path(path)
    if not path or path == '' then return false end
    return not path:match('^%a[%w+.-]*://') and not path:match('^ytdl://')
end

local function show(message, duration)
    mp.osd_message(message, duration or 2)
end

local function run_powershell(mode, extra, callback)
    local args = {
        'powershell', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-STA', '-ExecutionPolicy', 'Bypass', '-File', save_dialog, '-Mode', mode,
    }
    for _, value in ipairs(extra or {}) do table.insert(args, value) end
    mp.command_native_async({
        name = 'subprocess', args = args, capture_stdout = true, capture_stderr = true,
        playback_only = false,
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            callback(nil)
            return
        end
        local output = trim(result.stdout)
        callback(output ~= '' and output or nil)
    end)
end

local function choose_path(mode, suggested_path, callback)
    local extra = {}
    if suggested_path and suggested_path ~= '' then
        extra = {'-SuggestedPath', suggested_path}
    end
    run_powershell(mode, extra, callback)
end

local function choose_subtitle_action(message, callback)
    run_powershell('subtitle-warning', {'-Warning', message}, callback)
end

local function with_paused_video(callback)
    local was_paused = mp.get_property_bool('pause', false)
    mp.set_property_bool('pause', true)
    callback(function() mp.set_property_bool('pause', was_paused) end)
end

local function screenshot_original()
    with_paused_video(function(resume)
        choose_path('image', nil, function(path)
            if not path then
                resume()
                return
            end
            if not image_extensions[file_extension(path)] then
                resume()
                show('截图格式仅支持 PNG、JPEG 或 WebP', 3)
                return
            end
            mp.command_native_async({
                name = 'screenshot-to-file', filename = path, flags = 'video',
            }, function(success, _, error)
                resume()
                if success then
                    show('已保存原始截图：' .. path, 3)
                else
                    msg.error('[capture_tools] screenshot failed: ' .. tostring(error))
                    show('原始截图失败', 3)
                end
            end)
        end)
    end)
end

local function is_external_subtitle(track)
    return track.external == true or (track['external-filename'] or '') ~= ''
end

local function subtitle_codec(track)
    local codec = (track.codec or ''):lower()
    if codec ~= '' then return codec end
    return file_extension(track['external-filename'])
end

local function is_text_subtitle(track)
    return text_subtitle_codecs[subtitle_codec(track)] == true
end

local function subtitle_label(record)
    local track = record.track
    if track.title and track.title ~= '' then return track.title end
    if track.lang and track.lang ~= '' then return track.lang end
    local filename = basename(track['external-filename'])
    if filename ~= '' then return filename end
    return '字幕轨 ' .. tostring(record.index + 1)
end

local function collect_subtitle_tracks()
    local embedded, external = {}, {}
    local embedded_index = 0
    local seen_external_paths = {}
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type == 'sub' then
            if is_external_subtitle(track) then
                local filename = track['external-filename']
                if filename and filename ~= '' and not seen_external_paths[filename] then
                    table.insert(external, {track = track, path = filename, index = #external})
                    seen_external_paths[filename] = true
                end
            else
                table.insert(embedded, {track = track, index = embedded_index})
                embedded_index = embedded_index + 1
            end
        end
    end
    return embedded, external
end

local function incompatible_subtitles(container, embedded, external)
    if container == 'mkv' then return {} end
    local incompatible = {}
    for _, record in ipairs(embedded) do
        if not is_text_subtitle(record.track) then table.insert(incompatible, record) end
    end
    for _, record in ipairs(external) do
        if not is_text_subtitle(record.track) then table.insert(incompatible, record) end
    end
    return incompatible
end

local function append(args, values)
    for _, value in ipairs(values) do table.insert(args, value) end
end

local function is_incompatible(record, incompatible)
    for _, item in ipairs(incompatible) do
        if item == record then return true end
    end
    return false
end

local function append_subtitle_metadata(args, output_index, record)
    local track = record.track
    if track.title and track.title ~= '' then
        append(args, {'-metadata:s:s:' .. output_index, 'title=' .. track.title})
    end
    if track.lang and track.lang ~= '' and track.lang ~= 'und' then
        append(args, {'-metadata:s:s:' .. output_index, 'language=' .. track.lang})
    end
end

local function build_export_args(source, start_time, duration, output, container, embedded, external, incompatible, copy_audio)
    local args = {
        ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-i', source,
    }

    local external_inputs = {}
    for _, record in ipairs(external) do
        if not is_incompatible(record, incompatible) then
            table.insert(args, '-i')
            table.insert(args, record.path)
            record.input_index = #external_inputs + 1
            table.insert(external_inputs, record)
        end
    end

    append(args, {'-ss', string.format('%.6f', start_time), '-t', string.format('%.6f', duration), '-map', '0:v:0', '-map', '0:a?'})
    local output_subtitle_index = 0
    for _, record in ipairs(embedded) do
        if not is_incompatible(record, incompatible) then
            append(args, {'-map', '0:s:' .. record.index .. '?'})
            append_subtitle_metadata(args, output_subtitle_index, record)
            output_subtitle_index = output_subtitle_index + 1
        end
    end
    for _, record in ipairs(external_inputs) do
        append(args, {'-map', record.input_index .. ':s:0?'})
        append_subtitle_metadata(args, output_subtitle_index, record)
        output_subtitle_index = output_subtitle_index + 1
    end

    if container == 'webm' then
        append(args, {
            '-c:v', 'libvpx-vp9', '-crf', '32', '-b:v', '0',
            '-c:a', 'libopus', '-b:a', '128k', '-c:s', 'webvtt',
        })
    else
        append(args, {'-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18'})
        if copy_audio then
            append(args, {'-c:a', 'copy'})
        else
            append(args, {'-c:a', 'aac', '-b:a', '192k'})
        end
        append(args, {'-c:s', container == 'mkv' and 'copy' or 'mov_text'})
    end

    append(args, {'-map_metadata', '0', '-map_chapters', '-1', output})
    return args
end

local function export_clip(source, start_time, duration, output, container, embedded, external, incompatible, resume)
    local function complete(success, result, audio_reencoded)
        resume()
        if success and result and result.status == 0 then
            clip_start, clip_source = nil, nil
            local suffix = audio_reencoded and '（音频已转换为 AAC）' or ''
            show('视频片段已导出' .. suffix .. '：' .. output, 4)
        else
            local detail = result and (result.stderr or result.error_string) or 'unknown error'
            msg.error('[capture_tools] ffmpeg export failed: ' .. tostring(detail))
            show('视频导出失败，请检查源文件或输出格式', 4)
        end
    end

    local function run(copy_audio)
        local args = build_export_args(source, start_time, duration, output, container, embedded, external, incompatible, copy_audio)
        mp.command_native_async({
            name = 'subprocess', args = args, capture_stderr = true, playback_only = false,
        }, function(success, result)
            if success and result and result.status == 0 then
                complete(true, result, not copy_audio)
            elseif copy_audio and (container == 'mp4' or container == 'mov') then
                show('正在转换不兼容的音频…', 3)
                run(false)
            else
                complete(false, result, not copy_audio)
            end
        end)
    end

    show('正在导出视频片段…', 3)
    run(true)
end

local function start_clip()
    local path = mp.get_property('path')
    local time = mp.get_property_number('time-pos')
    if not is_local_path(path) or not time then
        show('I 仅支持本地视频设置截取起点', 3)
        return
    end
    clip_start = math.max(0, time)
    clip_source = path
    show(string.format('已设置截取起点：%s', mp.get_property_osd('time-pos')), 3)
end

local function finish_clip()
    local path = mp.get_property('path')
    local time = mp.get_property_number('time-pos')
    if not clip_start or clip_source ~= path then
        show('请先按 I 设置截取起点', 3)
        return
    end
    if not time or time <= clip_start then
        show('终点必须晚于起点', 3)
        return
    end
    if not is_local_path(path) then
        show('O 仅支持本地视频导出', 3)
        return
    end

    local start_time, duration = clip_start, time - clip_start
    with_paused_video(function(resume)
        choose_path('video', nil, function(output)
            if not output then
                resume()
                return
            end
            local container = file_extension(output)
            if not video_extensions[container] then
                resume()
                show('视频格式仅支持 MKV、MP4、WebM 或 MOV', 3)
                return
            end

            local embedded, external = collect_subtitle_tracks()
            local incompatible = incompatible_subtitles(container, embedded, external)
            if #incompatible == 0 then
                export_clip(path, start_time, duration, output, container, embedded, external, incompatible, resume)
                return
            end

            local labels = {}
            for _, record in ipairs(incompatible) do table.insert(labels, ' - ' .. subtitle_label(record)) end
            local warning = table.concat(labels, '\n')
            choose_subtitle_action(warning, function(action)
                if action == 'omit' then
                    export_clip(path, start_time, duration, output, container, embedded, external, incompatible, resume)
                elseif action == 'mkv' then
                    choose_path('video-mkv', replace_extension(output, 'mkv'), function(mkv_output)
                        if mkv_output then
                            export_clip(path, start_time, duration, mkv_output, 'mkv', embedded, external, {}, resume)
                        else
                            resume()
                        end
                    end)
                else
                    resume()
                end
            end)
        end)
    end)
end

mp.register_event('file-loaded', function()
    if clip_source and clip_source ~= mp.get_property('path') then
        clip_start, clip_source = nil, nil
    end
end)

mp.add_key_binding(nil, 'capture-screenshot-original', screenshot_original)
mp.add_key_binding(nil, 'capture-start-clip', start_clip)
mp.add_key_binding(nil, 'capture-finish-clip', finish_clip)
