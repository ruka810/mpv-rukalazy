local mp = require 'mp'
local utils = require 'mp.utils'

local MARKER = 'mpv-preloaded-playlist'
local temp_dir = os.getenv('TEMP') or os.getenv('TMP')
    or mp.command_native({ 'expand-path', '~~/_cache' })
local bridge = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/publish_v13/mpv-cookie-bridge.exe' })
local python = mp.command_native({ 'expand-path', '~~/../python.exe' })
local bilibili_fetcher = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/bilibili_cookie_fetch.py' })
local ytdlp = bridge
local BILIBILI_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36'

local request_id = 0
local pending_playlist_start = nil
local generated_files = {}

-- Ctrl+V requests a single-video load: skip Bilibili collection/part
-- expansion for this load and tell yt-dlp not to expand playlists.
local suppress_expand_once = false
local saved_ytdlp_options = nil

local function is_preloaded(url)
    return type(url) == 'string' and url:find(MARKER, 1, true) ~= nil
end

local function bilibili_host(url)
    if type(url) ~= 'string' then return nil end
    local host = url:match('^https?://([^/%?#:]+)')
    host = host and host:lower() or nil
    if host == 'bilibili.com' or (host and host:match('%.bilibili%.com$')) then return host end
end

local function query_parameter(url, wanted_key)
    local query = type(url) == 'string' and url:match('%?([^#]*)') or nil
    for parameter in (query or ''):gmatch('[^&]+') do
        local key, value = parameter:match('^([^=]+)=?(.*)$')
        if key and key:lower() == wanted_key then return value end
    end
    return nil
end

local function parse_bilibili_url(url)
    if type(url) ~= 'string' or is_preloaded(url) or not bilibili_host(url) then return nil end

    -- A Bilibili festival/campaign page can embed a normal video as
    -- /festival/<name>?bvid=BV..., rather than under /video/BV....
    local bvid = url:match('/video/([Bb][Vv][%w]+)') or query_parameter(url, 'bvid')
    if type(bvid) ~= 'string' or not bvid:match('^[Bb][Vv][%w]+$') then return nil end
    return bvid, tonumber(query_parameter(url, 'p'))
end

local function is_bilibili_collection_url(url)
    if type(url) ~= 'string' or is_preloaded(url) then return false end

    local without_fragment = url:match('^(.-)#') or url
    local path = without_fragment:match('^https?://[^/]+([^?]*)')
    local host = without_fragment:match('^https?://([^/%?]+)')
    if not path or not host then return false end

    host = host:lower()
    if host ~= 'bilibili.com' and not host:match('%.bilibili%.com$') then return false end

    path = path:lower()
    return path:match('^/medialist/play/') ~= nil
        or path:match('^/list/') ~= nil
        or path:match('^/festival/') ~= nil
        or path:match('^/bangumi/play/') ~= nil
        or path:match('^/%d+/favlist') ~= nil
        or path:match('^/%d+/lists') ~= nil
end

local function add_proxy(args)
    local options = mp.get_property_native('ytdl-raw-options') or {}
    if type(options.proxy) == 'string' and options.proxy ~= '' then
        table.insert(args, '--proxy')
        table.insert(args, options.proxy)
    end
end

local function bilibili_fetch_args(url, output)
    -- The helper uses Chrome Bridge cookies when available and falls back to an
    -- anonymous request for Bilibili's public metadata API when it is not.
    local args = {
        python,
        bilibili_fetcher,
        '--bridge', bridge,
        '--url', url,
        '--user-agent', BILIBILI_USER_AGENT,
    }
    if output then
        table.insert(args, '--output')
        table.insert(args, output)
    end
    add_proxy(args)
    return args
end

local function add_ytdlp_proxy_and_cookie(args)
    local options = mp.get_property_native('ytdl-raw-options') or {}
    if type(options.proxy) == 'string' and options.proxy ~= '' then
        table.insert(args, '--proxy')
        table.insert(args, options.proxy)
    end
end

local function cleanup_generated_files()
    for path in pairs(generated_files) do
        generated_files[path] = nil
        os.remove(path)
    end
end

local function reset_playlist_start()
    if pending_playlist_start ~= nil then
        mp.set_property('playlist-start', 'auto')
        pending_playlist_start = nil
    end
    cleanup_generated_files()
end

local function restore_ytdlp_options()
    if not saved_ytdlp_options then return end
    local options = mp.get_property_native('ytdl-raw-options') or {}
    options['yes-playlist'] = saved_ytdlp_options.yes_playlist
    options['no-playlist'] = saved_ytdlp_options.no_playlist
    mp.set_property_native('ytdl-raw-options', options)
    saved_ytdlp_options = nil
end

local function arm_single_video_load()
    restore_ytdlp_options()
    local options = mp.get_property_native('ytdl-raw-options') or {}
    saved_ytdlp_options = {
        yes_playlist = options['yes-playlist'],
        no_playlist = options['no-playlist'],
    }
    options['yes-playlist'] = nil
    options['no-playlist'] = ''
    mp.set_property_native('ytdl-raw-options', options)
end

local function clean_m3u_text(value)
    return tostring(value or ''):gsub('[\r\n]', ' ')
end

local function create_playlist_file(bvid, entries)
    local path = utils.join_path(temp_dir, string.format(
        'mpv-bilibili-playlist-%s-%d-%d.m3u8', bvid, os.time(), request_id))
    local file, error = io.open(path, 'wb')
    if not file then return nil, error end

    file:write('\239\187\191#EXTM3U\n')
    for _, entry in ipairs(entries) do
        local title = clean_m3u_text(entry.title)
        local url = clean_m3u_text(entry.url)
        file:write('#EXTINF:-1,', title, '\n', url, '#', MARKER, '\n')
    end
    file:close()
    generated_files[path] = true
    return path
end

local function make_page_entries(bvid, video)
    local pages = video.pages
    if type(pages) ~= 'table' or #pages < 2 then return nil end

    local entries = {}
    for index, page in ipairs(pages) do
        local part = page.part or page.title or ('P' .. index)
        entries[#entries + 1] = {
            title = string.format('%s p%02d %s', video.title or bvid, index, part),
            url = string.format('https://www.bilibili.com/video/%s?p=%d', bvid, index),
        }
    end
    return entries
end

local function make_ugc_season_entries(video)
    local season = video.ugc_season
    if type(season) ~= 'table' or tonumber(season.ep_count) == nil or season.ep_count < 2 then return nil end

    local entries = {}
    for _, section in ipairs(season.sections or {}) do
        for _, episode in ipairs(section.episodes or {}) do
            if type(episode.bvid) == 'string' and episode.bvid ~= '' then
                local pages = type(episode.pages) == 'table' and episode.pages or {}
                if #pages == 0 then pages = { episode.page or {} } end

                for index, page in ipairs(pages) do
                    local page_number = tonumber(page.page) or index
                    local part = page.part or page.title
                    local title = episode.title or episode.bvid
                    if part and part ~= '' then
                        title = string.format('%s p%02d %s', title, page_number, part)
                    elseif #pages > 1 then
                        title = string.format('%s p%02d', title, page_number)
                    end
                    entries[#entries + 1] = {
                        title = title,
                        url = string.format('https://www.bilibili.com/video/%s?p=%d', episode.bvid, page_number),
                        bvid = episode.bvid,
                        page = page_number,
                    }
                end
            end
        end
    end
    return #entries >= 2 and entries or nil
end

local function find_season_index(entries, bvid, requested_page)
    local wanted = bvid:lower()
    local wanted_page = requested_page or 1
    local first_bvid_index
    for index, entry in ipairs(entries) do
        if entry.bvid and entry.bvid:lower() == wanted then
            first_bvid_index = first_bvid_index or index
            if entry.page == wanted_page then return index end
        end
    end
    return first_bvid_index or 1
end

local function url_from_flat_entry(entry)
    if type(entry.webpage_url) == 'string' and entry.webpage_url ~= '' then return entry.webpage_url end
    if type(entry.original_url) == 'string' and entry.original_url ~= '' then return entry.original_url end
    if type(entry.url) == 'string' and entry.url:match('^https?://') then return entry.url end
    if type(entry.id) == 'string' and entry.id:match('^[Bb][Vv][%w]+$') then
        return 'https://www.bilibili.com/video/' .. entry.id
    end
end

local function bvid_from_url(url)
    if not bilibili_host(url) then return nil end
    local bvid = url:match('/video/([Bb][Vv][%w]+)') or query_parameter(url, 'bvid')
    return type(bvid) == 'string' and bvid:match('^[Bb][Vv][%w]+$') and bvid or nil
end

local function make_flat_playlist_entries(data)
    local entries = {}
    for _, item in ipairs(data.entries or {}) do
        local url = url_from_flat_entry(item)
        if url then
            local bvid = bvid_from_url(url) or item.id
            local title = item.title or item.fulltitle
            entries[#entries + 1] = {
                title = title or bvid or url,
                url = url,
                bvid = bvid,
                needs_title = not title and type(bvid) == 'string' and bvid:match('^[Bb][Vv][%w]+$') ~= nil,
            }
        end
    end
    return #entries >= 2 and entries or nil
end

local function request_bilibili_title(bvid, callback)
    local args = bilibili_fetch_args('https://api.bilibili.com/x/web-interface/view?bvid=' .. bvid)

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result)
        local response = success and result and result.status == 0 and utils.parse_json(result.stdout or '') or nil
        local video = response and response.code == 0 and response.data or nil
        callback(video and video.title or nil)
    end)
end

local function preload_flat_entry_titles(entries, callback)
    local queue = {}
    for _, entry in ipairs(entries) do
        if entry.needs_title then table.insert(queue, entry) end
    end
    if #queue == 0 then callback() return end

    local next_index, active, completed = 1, 0, 0
    local max_concurrent = 6
    local function launch_next()
        while active < max_concurrent and next_index <= #queue do
            local entry = queue[next_index]
            next_index = next_index + 1
            active = active + 1
            request_bilibili_title(entry.bvid, function(title)
                if title and title ~= '' then entry.title = title end
                active = active - 1
                completed = completed + 1
                if completed == #queue then
                    callback()
                else
                    launch_next()
                end
            end)
        end
    end
    launch_next()
end

local function load_preloaded_playlist(source_path, token, label, entries, selected_index, kind)
    if token ~= request_id or mp.get_property('stream-open-filename') ~= source_path or not entries then return end

    local playlist_file, write_error = create_playlist_file(label, entries)
    if playlist_file then
        pending_playlist_start = (selected_index or 1) - 1
        mp.set_property_number('playlist-start', pending_playlist_start)
        -- stream-open-filename treats local M3U files as media in this mpv
        -- build.  loadlist uses the playlist parser and preserves #EXTINF.
        mp.commandv('loadlist', playlist_file, 'replace')
        if pending_playlist_start > 0 then
            mp.commandv('playlist-play-index', tostring(pending_playlist_start))
        end
        mp.msg.info(string.format('Bilibili: preloaded %d titled playlist entries', #entries))
        mp.osd_message(string.format('已加载 Bilibili%s（%d 项）', kind == 'collection' and '合集' or '分P', #entries), 2)
    else
        mp.msg.warn('[bilibili_playlist] Cannot create playlist: ' .. tostring(write_error))
    end
end

local function run_view_request(hook, token, source_path, bvid, requested_page)
    local api_file = utils.join_path(temp_dir, string.format(
        'mpv-bilibili-view-%s-%d-%d.json', bvid, os.time(), token))
    local args = bilibili_fetch_args('https://api.bilibili.com/x/web-interface/view?bvid=' .. bvid, api_file)

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        local file = io.open(api_file, 'rb')
        local body = file and file:read('*all') or nil
        if file then file:close() end
        os.remove(api_file)

        local response = body and utils.parse_json(body) or nil
        local video = response and response.code == 0 and response.data or nil
        local entries, selected_index, kind
        if success and result and result.status == 0 and video then
            -- A Bilibili UGC season always takes precedence over individual
            -- parts, including links that contain an explicit ?p=N.
            local season_entries = make_ugc_season_entries(video)
            if season_entries then
                entries = season_entries
                selected_index = find_season_index(entries, bvid, requested_page)
                kind = 'collection'
            else
                entries = make_page_entries(bvid, video)
                selected_index = math.max(1, math.min(requested_page or 1, entries and #entries or 1))
                kind = 'parts'
            end
        end

        if entries then
            load_preloaded_playlist(source_path, token, bvid, entries, selected_index, kind)
        elseif token == request_id then
            mp.osd_message('未读取到 Bilibili 合集，保留原视频/分P', 3)
            if error then mp.msg.verbose('[bilibili_playlist] Metadata request failed: ' .. tostring(error)) end
        end
        hook:cont()
    end)
end

local function run_flat_playlist_request(hook, token, source_path)
    local args = { ytdlp, '--flat-playlist', '--dump-single-json', '--no-warnings', '--no-progress' }
    add_ytdlp_proxy_and_cookie(args)
    table.insert(args, source_path)

    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, error)
        local data = success and result and result.status == 0 and utils.parse_json(result.stdout or '') or nil
        local entries = data and make_flat_playlist_entries(data) or nil
        if entries then
            preload_flat_entry_titles(entries, function()
                load_preloaded_playlist(source_path, token, 'collection', entries, 1, 'collection')
                hook:cont()
            end)
            return
        elseif error and token == request_id then
            mp.msg.verbose('[bilibili_playlist] Flat playlist metadata request failed: ' .. tostring(error))
        end
        hook:cont()
    end)
end

-- Fetch Bilibili's lightweight view payload before ytdl_hook. It contains both
-- multi-part titles and the UGC collection that yt-dlp cannot infer from a BV URL.
-- Explicit collection URLs use yt-dlp's flat metadata so their media streams
-- remain unresolved until the user plays an item.
mp.add_hook('on_load', 5, function(hook)
    -- A pending Ctrl+V single-video request skips this expansion; the
    -- priority-9 hook below consumes the flag and arms yt-dlp no-playlist.
    if suppress_expand_once then return end

    local source_path = mp.get_property('stream-open-filename') or ''
    local bvid, requested_page = parse_bilibili_url(source_path)
    local is_collection = not bvid and is_bilibili_collection_url(source_path)
    if not bvid and not is_collection then return end

    -- Preserve the existing append-to-playlist behavior and avoid re-expanding
    -- generated entries when mpv advances through them.
    if mp.get_property_number('playlist-count', 0) > 1 then return end
    if is_collection and not utils.file_info(ytdlp) then return end

    request_id = request_id + 1
    local token = request_id
    hook:defer()
    mp.osd_message('正在读取 Bilibili 合集标题', 2)
    if bvid then
        run_view_request(hook, token, source_path, bvid, requested_page)
    else
        run_flat_playlist_request(hook, token, source_path)
    end
end)

mp.register_event('file-loaded', reset_playlist_start)
mp.register_event('end-file', reset_playlist_start)
mp.register_event('shutdown', cleanup_generated_files)

-- ytdl_hook runs at priority 10, so arm no-playlist before it and restore
-- afterwards, matching preloaded_playlist_guard's lifecycle.
mp.add_hook('on_load', 9, function()
    if suppress_expand_once then
        suppress_expand_once = false
        arm_single_video_load()
    end
end)
mp.add_hook('on_load', 11, restore_ytdlp_options)
mp.add_hook('on_load_fail', 11, function()
    suppress_expand_once = false
    restore_ytdlp_options()
end)
mp.register_event('file-loaded', restore_ytdlp_options)
mp.register_event('end-file', restore_ytdlp_options)
mp.register_event('shutdown', restore_ytdlp_options)

mp.register_script_message('suppress-expand', function() suppress_expand_once = true end)
mp.register_script_message('allow-expand', function()
    suppress_expand_once = false
    restore_ytdlp_options()
end)
