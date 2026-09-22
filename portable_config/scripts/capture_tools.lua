local msg = require 'mp.msg'

local save_dialog = mp.command_native({'expand-path', '~~/tools/select_save_path.ps1'})
local ffmpeg = 'ffmpeg'

-- 定位便携根目录下的 VSPipe.exe（脚本在 portable_config/scripts 内，向上找含 VSPipe.exe 的目录）
local function locate_vspipe()
    local src = debug.getinfo(1, 'S').source:match('^@(.+)') or ''
    local dir = src:match('^(.-)[/\\][^/\\]+$') or ''
    for _ = 1, 6 do
        if dir ~= '' and io.open(dir .. '/VSPipe.exe', 'r') then
            return dir .. '/VSPipe.exe'
        end
        dir = dir:match('^(.-)[/\\][^/\\]+$') or ''
    end
    return nil
end
local vspipe = locate_vspipe()

local clip_start = nil
local clip_source = nil
local shader_clip_start = nil
local shader_clip_source = nil

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

local function log_error(context, detail)
    local msg_text = tostring(detail or 'unknown')
    msg.error('[capture_tools] ' .. context .. ': ' .. msg_text)
    local log_path = mp.command_native({'expand-path', '~~/tools/capture_tools_error.log'})
    local f = io.open(log_path, 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' [' .. context .. ']\n' .. msg_text .. '\n\n')
        f:close()
    end
end

local function detect_upscale_shader()
    -- 识别文件名含 x2/x3/x4/Upscale 的超分着色器，返回建议倍数（2/3/4）或 nil
    local shaders = mp.get_property_native('options/glsl-shaders')
    if type(shaders) ~= 'table' then return nil end
    local best = nil
    for _, shader in ipairs(shaders) do
        if type(shader) == 'string' then
            local name = basename(shader):lower()
            local factor = name:match('[xX](%d)') or name:match('(%d)[xX]')
            if factor then
                local n = tonumber(factor)
                if n and n > 1 then best = math.max(best or 0, n) end
            end
        end
    end
    return best
end

local function get_vapoursynth_script()
    -- 从当前 vf 滤镜中提取 vapoursynth 脚本路径（params.file），无则返回 nil
    local vf = mp.get_property_native('options/vf')
    if type(vf) ~= 'table' then return nil end
    for _, item in ipairs(vf) do
        if type(item) == 'table' and item.name == 'vapoursynth' and type(item.params) == 'table' then
            local file = item.params.file
            if type(file) == 'string' and file ~= '' then
                return mp.command_native({'expand-path', file})
            end
        end
    end
    return nil
end

local function parse_source_fps(source)
    -- 用 ffprobe 解析源视频帧率，返回 fps_num, fps_den（如 30,1）；失败返回 nil
    local result = mp.command_native({
        name = 'subprocess', args = {
            'ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_entries', 'stream=r_frame_rate', '-of', 'csv=p=0', source,
        },
        capture_stdout = true, capture_stderr = true, playback_only = false,
    })
    if not result or result.status ~= 0 then return nil end
    local num, den = result.stdout:match('(%d+)/(%d+)')
    if not num then return nil end
    return tonumber(num), tonumber(den)
end

local function build_offline_vpy(original_path, source, fps_num, fps_den)
    -- 生成离线版 vpy：替换 mpv 注入的 video_in 为源加载，并注入 container_fps
    local f = io.open(original_path, 'r')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    if not content or content == '' then return nil end
    local abs_src = source:gsub('\\', '/')
    content = content:gsub('clip%s*=%s*video_in',
        'clip = core.bs.VideoSource(r"' .. abs_src .. '", fpsnum=' .. fps_num .. ', fpsden=' .. fps_den .. ')')
    content = 'container_fps = ' .. fps_num .. '/' .. fps_den .. '\n' .. content
    local dir = mp.command_native({'expand-path', '~~/tools'})
    local temp = dir .. '/vs_offline_' .. os.time() .. math.random(1000, 9999) .. '.vpy'
    local out = io.open(temp, 'w')
    if not out then return nil end
    out:write(content)
    out:close()
    return temp
end

local function query_vs_fps(offline_vpy)
    -- 运行 VSPipe --info 获取补帧后的输出帧率，返回 fps（浮点）或 nil
    if not vspipe then return nil end
    local result = mp.command_native({
        name = 'subprocess', args = { vspipe, '--info', offline_vpy },
        capture_stdout = true, capture_stderr = true, playback_only = false,
    })
    if not result or result.status ~= 0 then return nil end
    local num, den = result.stdout:match('FPS:%s*(%d+)/(%d+)')
    if not num then return nil end
    return tonumber(num) / tonumber(den)
end

local function build_render_chain(scale)
    local filters = {}

    local vf = mp.get_property_native('options/vf')
    if type(vf) == 'table' then
        for _, item in ipairs(vf) do
            if type(item) == 'table' and item.name and item.name ~= '' then
                -- 跳过 mpv 专属、ffmpeg 无法识别的滤镜（如 vapoursynth）
                local name = item.name:lower()
                if name ~= 'vapoursynth' and name ~= 'gpu' and name ~= 'hwupload' and name ~= 'sub' then
                    local spec = item.name
                    local params = type(item.params) == 'table' and item.params or {}
                    local parts = {}
                    for key, value in pairs(params) do
                        if value ~= nil and value ~= '' then
                            table.insert(parts, key .. '=' .. tostring(value))
                        end
                    end
                    if #parts > 0 then
                        spec = spec .. '=' .. table.concat(parts, ':')
                    end
                    table.insert(filters, spec)
                end
            end
        end
    end

    if scale and scale > 1 then
        table.insert(filters, 'scale=' .. scale .. '*iw:' .. scale .. '*ih:flags=lanczos')
    end

    local shaders = mp.get_property_native('options/glsl-shaders')
    if type(shaders) == 'table' then
        for _, shader in ipairs(shaders) do
            if type(shader) == 'string' and shader ~= '' then
                local path = mp.command_native({'expand-path', shader})
                if path and path ~= '' then
                    path = path:gsub('\\', '/'):gsub(':', '\\:')
                    table.insert(filters, "libplacebo=custom_shader_path='" .. path .. "'")
                end
            end
        end
    end

    if #filters == 0 then return nil end
    return table.concat(filters, ',')
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

local function screenshot_window()
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
                name = 'screenshot-to-file', filename = path, flags = 'scaled+subtitles',
            }, function(success, _, error)
                resume()
                if success then
                    show('已保存窗口截图：' .. path, 3)
                else
                    msg.error('[capture_tools] screenshot failed: ' .. tostring(error))
                    show('窗口截图失败', 3)
                end
            end)
        end)
    end)
end

local function screenshot_rendered()
    local path = mp.get_property('path')
    local time = mp.get_property_number('time-pos')
    if not is_local_path(path) or not time then
        show('渲染截图仅支持本地视频', 3)
        return
    end
    local chain = build_render_chain(nil)
    if not chain then
        show('当前未启用 vf 滤镜或着色器，无法渲染截图', 3)
        return
    end
    with_paused_video(function(resume)
        choose_path('image', nil, function(output)
            if not output then
                resume()
                return
            end
            if not image_extensions[file_extension(output)] then
                resume()
                show('截图格式仅支持 PNG、JPEG 或 WebP', 3)
                return
            end
            local args = {
                ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
                '-ss', string.format('%.6f', time), '-i', path,
                '-frames:v', '1', '-vf', chain, '-map', '0:v:0', output,
            }
            mp.command_native_async({
                name = 'subprocess', args = args, capture_stderr = true, playback_only = false,
            }, function(success, result)
                resume()
                if success and result and result.status == 0 then
                    show('已保存渲染截图：' .. output, 3)
                else
                    log_error('rendered screenshot failed', result and result.stderr or 'unknown')
                    show('渲染截图失败，详情见 portable_config/tools/capture_tools_error.log', 3)
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

local function build_vs_export_args(source, start_time, duration, output, container, embedded, external, incompatible, copy_audio, vf_chain, pipe_name)
    -- 输入 0 = 命名管道（VSPipe 补帧后的 y4m 视频），输入 1 = 源文件（音频/内嵌字幕）
    local args = {
        ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
        '-i', pipe_name,
        '-ss', string.format('%.6f', start_time), '-t', string.format('%.6f', duration),
        '-i', source,
    }

    local external_inputs = {}
    for _, record in ipairs(external) do
        if not is_incompatible(record, incompatible) then
            table.insert(args, '-i')
            table.insert(args, record.path)
            record.input_index = #external_inputs + 2
            table.insert(external_inputs, record)
        end
    end

    if vf_chain and vf_chain ~= '' then
        append(args, {'-vf', vf_chain})
    end

    append(args, {'-map', '0:v:0', '-map', '1:a?'})
    local output_subtitle_index = 0
    for _, record in ipairs(embedded) do
        if not is_incompatible(record, incompatible) then
            append(args, {'-map', '1:s:' .. record.index .. '?'})
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

    append(args, {'-map_metadata', '1', '-map_chapters', '-1', output})
    return args
end

local function export_clip_vs(source, start_time, duration, output, container, embedded, external, incompatible, resume, vf_chain, clear_state)
    -- 离线渲染导出：VSPipe 跑 vapoursynth 脚本（补帧等）-> 命名管道 -> ffmpeg 读管道叠着色器/编码
    local done = false
    local function complete(success, result, audio_reencoded, offline_vpy)
        if done then return end
        done = true
        resume()
        if offline_vpy then os.remove(offline_vpy) end
        if success and result and result.status == 0 then
            if clear_state then clear_state() end
            local suffix = audio_reencoded and '（音频已转换为 AAC）' or ''
            show('视频片段已导出' .. suffix .. '：' .. output, 4)
        else
            log_error('vspipe export failed', result and (result.stderr or result.error_string) or 'unknown error')
            show('视频导出失败，详情见 portable_config/tools/capture_tools_error.log', 4)
        end
    end

    local function run_with_vspipe(offline_vpy, fps, pipe_name, copy_audio)
        -- VSPipe 帧号（补帧后）：start/end 均为输出帧索引
        local start_frame = math.floor(start_time * fps)
        local end_frame = math.ceil((start_time + duration) * fps)
        if end_frame <= start_frame then
            complete(false, { stderr = 'frame range too short' }, false, offline_vpy)
            return
        end
        local vs_args = { vspipe, '-c', 'y4m', '--start', tostring(start_frame), '--end', tostring(end_frame), offline_vpy, pipe_name }
        mp.command_native_async({
            name = 'subprocess', args = vs_args, capture_stderr = true, playback_only = false,
        }, function(vs_ok, vs_result)
            -- VSPipe 结束后其命名管道写入端已关闭；这里仅记录错误
            if not vs_ok or not vs_result or vs_result.status ~= 0 then
                complete(false, vs_result, false, offline_vpy)
            end
        end)
        -- ffmpeg 可能早于 VSPipe 创建管道而连接失败，延迟重试直到管道就绪
        local function run_ffmpeg(attempt)
            local ff_args = build_vs_export_args(source, start_time, duration, output, container, embedded, external, incompatible, copy_audio, vf_chain, pipe_name)
            mp.command_native_async({
                name = 'subprocess', args = ff_args, capture_stderr = true, playback_only = false,
            }, function(success, result)
                if success and result and result.status == 0 then
                    complete(true, result, not copy_audio, offline_vpy)
                elseif result and result.stderr and result.stderr:match('No such file') and attempt < 30 then
                    show('正在等待补帧管道就绪…', 2)
                    mp.add_timeout(0.5, function() run_ffmpeg(attempt + 1) end)
                elseif copy_audio and (container == 'mp4' or container == 'mov') then
                    show('正在转换不兼容的音频…', 3)
                    run_with_vspipe(offline_vpy, fps, pipe_name, false)
                else
                    complete(false, result, not copy_audio, offline_vpy)
                end
            end)
        end
        run_ffmpeg(1)
    end

    show('正在离线渲染导出（VSPipe 补帧 + 着色器）…', 3)
    local fps_num, fps_den = parse_source_fps(source)
    if not fps_num then
        show('无法解析源视频帧率，无法离线渲染', 4)
        resume()
        return
    end
    local vs_script = get_vapoursynth_script()
    if not vs_script or not vspipe then
        show('未找到 vapoursynth 脚本或 VSPipe，无法离线渲染', 4)
        resume()
        return
    end
    local offline_vpy = build_offline_vpy(vs_script, source, fps_num, fps_den)
    if not offline_vpy then
        show('无法生成离线渲染脚本', 4)
        resume()
        return
    end
    local fps = query_vs_fps(offline_vpy)
    if not fps then
        complete(false, { stderr = 'VSPipe --info failed' }, false, offline_vpy)
        return
    end
    local pipe_name = '\\\\.\\pipe\\mpvclipvs_' .. os.time() .. '_' .. math.random(10000, 99999)
    run_with_vspipe(offline_vpy, fps, pipe_name, true)
end

local function build_export_args(source, start_time, duration, output, container, embedded, external, incompatible, copy_audio, vf_chain)
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

    if vf_chain and vf_chain ~= '' then
        append(args, {'-vf', vf_chain})
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

local function export_clip(source, start_time, duration, output, container, embedded, external, incompatible, resume, vf_chain, clear_state)
    local function complete(success, result, audio_reencoded)
        resume()
        if success and result and result.status == 0 then
            if clear_state then clear_state() end
            local suffix = audio_reencoded and '（音频已转换为 AAC）' or ''
            show('视频片段已导出' .. suffix .. '：' .. output, 4)
        else
            log_error('ffmpeg export failed', result and (result.stderr or result.error_string) or 'unknown error')
            show('视频导出失败，详情见 portable_config/tools/capture_tools_error.log', 4)
        end
    end

    local function run(copy_audio)
        local args = build_export_args(source, start_time, duration, output, container, embedded, external, incompatible, copy_audio, vf_chain)
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

local function finish_clip_core(start_time, path, vf_chain, clear_state, exporter)
    local time = mp.get_property_number('time-pos')
    if not time or time <= start_time then
        show('终点必须晚于起点', 3)
        return
    end
    if not is_local_path(path) then
        show('仅支持本地视频导出', 3)
        return
    end

    local duration = time - start_time
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
            local exporter_fn = exporter or export_clip
            if #incompatible == 0 then
                exporter_fn(path, start_time, duration, output, container, embedded, external, incompatible, resume, vf_chain, clear_state)
                return
            end

            local labels = {}
            for _, record in ipairs(incompatible) do table.insert(labels, ' - ' .. subtitle_label(record)) end
            local warning = table.concat(labels, '\n')
            choose_subtitle_action(warning, function(action)
                if action == 'omit' then
                    exporter_fn(path, start_time, duration, output, container, embedded, external, incompatible, resume, vf_chain, clear_state)
                elseif action == 'mkv' then
                    choose_path('video-mkv', replace_extension(output, 'mkv'), function(mkv_output)
                        if mkv_output then
                            exporter_fn(path, start_time, duration, mkv_output, 'mkv', embedded, external, {}, resume, vf_chain, clear_state)
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

local function finish_clip()
    local path = mp.get_property('path')
    if not clip_start or clip_source ~= path then
        show('请先按 I 设置截取起点', 3)
        return
    end
    finish_clip_core(clip_start, path, nil, function()
        clip_start, clip_source = nil, nil
    end)
end

local function start_clip_rendered()
    local path = mp.get_property('path')
    local time = mp.get_property_number('time-pos')
    if not is_local_path(path) or not time then
        show('Ctrl+Shift+I 仅支持本地视频设置起点', 3)
        return
    end
    shader_clip_start = math.max(0, time)
    shader_clip_source = path
    show(string.format('已设置渲染导出起点：%s', mp.get_property_osd('time-pos')), 3)
end

local function finish_clip_rendered()
    local path = mp.get_property('path')
    if not shader_clip_start or shader_clip_source ~= path then
        show('请先按 Ctrl+Shift+I 设置起点', 3)
        return
    end
    -- 自动按当前超分着色器检测倍数（无超分则原分辨率 1x），不再手动选择
    local scale = detect_upscale_shader()
    local chain = build_render_chain(scale)
    -- 检测到 vapoursynth 滤镜（如 RIFE 补帧）时改用 VSPipe 离线渲染，确保补帧效果生效；
    -- 此时着色器链可为空（仅补帧、无着色器的情况也能导出）
    if get_vapoursynth_script() and vspipe then
        finish_clip_core(shader_clip_start, path, chain, function()
            shader_clip_start, shader_clip_source = nil, nil
        end, export_clip_vs)
        return
    end
    if not chain then
        show('当前未启用 vf 滤镜或着色器，无法渲染导出', 3)
        return
    end
    finish_clip_core(shader_clip_start, path, chain, function()
        shader_clip_start, shader_clip_source = nil, nil
    end)
end

mp.register_event('file-loaded', function()
    if clip_source and clip_source ~= mp.get_property('path') then
        clip_start, clip_source = nil, nil
    end
    if shader_clip_source and shader_clip_source ~= mp.get_property('path') then
        shader_clip_start, shader_clip_source = nil, nil
    end
end)

mp.add_key_binding(nil, 'capture-screenshot-original', screenshot_original)
mp.add_key_binding(nil, 'capture-screenshot-rendered', screenshot_rendered)
mp.add_key_binding(nil, 'capture-start-clip', start_clip)
mp.add_key_binding(nil, 'capture-finish-clip', finish_clip)
mp.add_key_binding(nil, 'capture-start-clip-rendered', start_clip_rendered)
mp.add_key_binding(nil, 'capture-finish-clip-rendered', finish_clip_rendered)
