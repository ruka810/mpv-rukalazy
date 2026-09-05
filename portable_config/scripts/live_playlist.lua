-- Tabbed playlist and session-scoped web favorites for uosc.

local mp = require 'mp'
local utils = require 'mp.utils'

local MENU_TYPE = 'live-playlist'
local NOTE_MENU_TYPE = 'live-playlist-note'
local FAVORITES_PATH = mp.command_native({'expand-path', '~~/live-favorites.json'})
local COOKIE_BRIDGE = mp.command_native({'expand-path', '~~/tools/chrome_cookie_bridge/publish_v13/mpv-cookie-bridge.exe'})

local active_tab = 'playlist'
local active_web_key = nil
local note_edit_key = nil
local session_items = {}
local items_by_key = {}
local title_refresh_queue = {}
local title_refresh_pending = {}
local title_refresh_running = false
local favorite_navigation = {
    active = false,
    current_key = nil,
    temporary_entry_id = nil,
    cleanup_entry_id = nil,
    pending = nil,
}
local FAVORITES_ACTIVE_PROPERTY = 'user-data/live_playlist/favorites-active'

local function is_text(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function normalize_url(value)
    local url = trim(value)
    if url == '' then return nil end
    return url:gsub('#.*$', '')
end

local function filename_from_path(value)
    local path = tostring(value or '')
    return path:match('([^/\\]+)$') or path
end

local function is_direct_media_url(value)
    local path = tostring(value or ''):match('^https?://[^/%?#]+([^?#]*)') or ''
    return path:lower():match('%.(3gp|aac|avi|flac|flv|m2ts|m3u8|m4a|m4v|mkv|mov|mp3|mp4|mpeg|mpg|oga|ogg|ogv|opus|ts|wav|webm|wmv)$') ~= nil
end

local function webpage_kind(value)
    local url = normalize_url(value)
    if not url or is_direct_media_url(url) then return nil end
    local host = url:match('^https?://([^/%?#:]+)')
    host = host and host:lower() or nil
    if not host then return nil end

    if host == 'live.bilibili.com' and (
        url:match('^https?://live%.bilibili%.com/%d+')
        or url:match('^https?://live%.bilibili%.com/blanc/%d+')
    ) then
        return 'bilibili-live'
    end
    if host == 'bilibili.com' or host:match('%.bilibili%.com$') then return 'bilibili-video' end
    if host == 'youtu.be' or host == 'youtube.com' or host:match('%.youtube%.com$') then return 'youtube-video' end
    return 'ytdl-web'
end

local function is_favoritable_web_context(context)
    return type(context) == 'table'
        and type(context.url) == 'string'
        and (context.kind == 'bilibili-live'
            or context.kind == 'bilibili-video'
            or context.kind == 'youtube-live'
            or context.kind == 'youtube-video'
            or context.kind == 'ytdl-web')
end

local function get_item(key)
    return key and items_by_key[key] or nil
end

local function is_valid_live_title(value, url)
    local title = trim(value)
    if title == '' or title:match('^https?://') or title:match('^//') or title:match('^%d+$') then return false end
    if title:match('^[%w%-]+%.[%w%.%-]+/') then return false end
    local source = trim(url)
    if title == source or title == source:gsub('^https?://', '') then return false end
    local filename = filename_from_path(source)
    if title == filename or title == filename:gsub('%?.*$', '') then return false end
    return true
end

local function display_title(item)
    if is_valid_live_title(item.title, item.url) then return item.title end
    return item.url
end

local function live_identity(value)
    local url = normalize_url(value)
    if not url then return nil end

    -- Lua patterns cannot apply a quantifier to a capture group, so an
    -- optional "(...)? " query group silently becomes a literal '?' and the
    -- whole pattern never matches.  Match the query part separately instead.
    local host, path = url:match('^https?://([^/%?#]+)([^?#]*)')
    host = host and host:lower() or nil
    if not host then return url end
    local query = url:match('%?[^#]*$') or ''

    if host == 'live.bilibili.com' then
        local room = path:match('^/blanc/(%d+)') or path:match('^/(%d+)')
        if room then return 'bilibili:' .. room end
    end

    if host == 'bilibili.com' or host:match('%.bilibili%.com$') then
        local video = path:match('^/video/(BV[%w]+)') or path:match('^/video/(av%d+)')
        if video then return 'bilibili-video:' .. video end
    end

    if host == 'youtu.be' or host == 'youtube.com' or host:match('%.youtube%.com$') then
        local video = path:match('^/([^/]+)')
        if host ~= 'youtu.be' then
            video = path:match('^/live/([^/]+)')
                or path:match('^/embed/([^/]+)')
                or path:match('^/shorts/([^/]+)')
                or (query or ''):match('[?&]v=([^&]+)')
        end
        if video and video ~= '' then return 'youtube:' .. video end
    end

    return host .. path .. query
end

local function item_key(value)
    return live_identity(value) or normalize_url(value)
end

local function ytdl_result_matches_live_url(data, url)
    if type(data) ~= 'table' then return false end
    local expected = live_identity(url)
    if not expected then return false end
    for _, field in ipairs({'webpage_url', 'original_url'}) do
        if live_identity(data[field]) == expected then return true end
    end
    return false
end

local function current_media_title(url)
    local title = trim(mp.get_property('media-title') or '')
    return is_valid_live_title(title, url) and title or nil
end

local function title_from_ytdl_output(output, url)
    if type(output) ~= 'string' or output == '' then return nil end
    local data = utils.parse_json(output)
    if not ytdl_result_matches_live_url(data, url) then return nil end
    for _, field in ipairs({'title', 'fulltitle'}) do
        local title = trim(data[field])
        if is_valid_live_title(title, url) then return title end
    end
    return nil
end

local function current_live_title(url, allow_media_title)
    local result = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result')
    local title = type(result) == 'table' and title_from_ytdl_output(result.stdout, url) or nil
    return title or (allow_media_title and current_media_title(url) or nil)
end

local function upsert_session_item(url, title, preserve_unverified_title, kind)
    local key = item_key(url)
    if not key then return nil end

    local item = items_by_key[key]
    if not item then
        local saved_title = trim(title)
        local accepted_title = is_valid_live_title(saved_title, url) and saved_title
            or preserve_unverified_title and saved_title or ''
        item = {
            key = key,
            url = url,
            title = accepted_title,
            note = '',
            favorite = false,
            kind = kind or webpage_kind(url),
        }
        items_by_key[key] = item
        session_items[#session_items + 1] = item
    elseif kind and not item.kind then
        item.kind = kind
    end
    return item
end

local function favorite_payload()
    local favorites = {}
    for _, item in ipairs(session_items) do
        if item.favorite then
            favorites[#favorites + 1] = {
                url = item.url,
                title = item.title or '',
                note = item.note or '',
                kind = item.kind or webpage_kind(item.url),
            }
        end
    end
    return {version = 2, favorites = favorites}
end

local function write_favorites()
    local content, format_error = utils.format_json(favorite_payload())
    if not content then
        mp.msg.error('[live_playlist] Cannot serialize favorites: ' .. tostring(format_error))
        return false
    end

    local temporary = FAVORITES_PATH .. '.tmp'
    local backup = FAVORITES_PATH .. '.bak'
    local file, open_error = io.open(temporary, 'wb')
    if not file then
        mp.msg.error('[live_playlist] Cannot write favorites: ' .. tostring(open_error))
        return false
    end
    file:write(content)
    file:flush()
    file:close()

    os.remove(backup)
    local had_previous = utils.file_info(FAVORITES_PATH) ~= nil
    if had_previous then
        local moved, move_error = os.rename(FAVORITES_PATH, backup)
        if not moved then
            os.remove(temporary)
            mp.msg.error('[live_playlist] Cannot replace favorites: ' .. tostring(move_error))
            return false
        end
    end

    local replaced, replace_error = os.rename(temporary, FAVORITES_PATH)
    if not replaced then
        if had_previous then os.rename(backup, FAVORITES_PATH) end
        os.remove(temporary)
        mp.msg.error('[live_playlist] Cannot finish favorites save: ' .. tostring(replace_error))
        return false
    end
    os.remove(backup)
    return true
end

local function update_item_title(item, title)
    if not item or not is_valid_live_title(title, item.url) or item.title == title then return false end
    local previous = item.title
    item.title = title
    if item.favorite and not write_favorites() then
        item.title = previous
        return false
    end
    return true
end

local function load_favorites()
    local file = io.open(FAVORITES_PATH, 'rb')
    if not file then return end
    local decoded = utils.parse_json(file:read('*all'))
    file:close()
    if type(decoded) ~= 'table' or type(decoded.favorites) ~= 'table' then
        mp.msg.warn('[live_playlist] Ignoring invalid live-favorites.json')
        return
    end

    for _, saved in ipairs(decoded.favorites) do
        if type(saved) == 'table' and is_text(saved.url) then
            local item = upsert_session_item(saved.url, trim(saved.title), true, saved.kind or webpage_kind(saved.url))
            if item then
                item.favorite = true
                item.note = trim(saved.note)
            end
        end
    end
end

local build_menu_data

local function refresh_menu()
    -- uosc ignores updates for other menu types. Sending the update directly
    -- avoids relying on its transient user-data property, which can be stale
    -- while a tab click is being dispatched.
    mp.commandv('script-message-to', 'uosc', 'update-menu', utils.format_json(build_menu_data()))
end

local function playlist_entry_at(index)
    local playlist = mp.get_property_native('playlist') or {}
    return index and playlist[index] or nil
end

local function entry_favorite_context(entry)
    if type(entry) ~= 'table' then return nil end
    local context = mp.get_property_native('user-data/web_source/context')
    if is_favoritable_web_context(context)
        and ((entry.id ~= nil and context.entry_id ~= nil
            and tostring(entry.id) == tostring(context.entry_id))
            or (entry.current == true and context.entry_id == nil)) then
        return {url = normalize_url(context.url), kind = context.kind}
    end

    local raw_url = entry.filename or entry.path
    local kind = webpage_kind(raw_url)
    if not kind then return nil end
    -- Generic HTTP pages are only considered collectible after yt-dlp has
    -- published a webpage context (or the URL was already seen/saved).
    if kind == 'ytdl-web' and not get_item(item_key(raw_url)) then return nil end
    return {url = normalize_url(raw_url), kind = kind}
end

local function playlist_items()
    local items = {}
    local force_filename = mp.get_property_native('osd-playlist-entry') == 'filename'
    for index, entry in ipairs(mp.get_property_native('playlist') or {}) do
        local title = type(entry.title) == 'string' and trim(entry.title) or ''
        local path = tostring(entry.filename or entry.path or '')
        local shown = (not force_filename and title ~= '') and title or filename_from_path(path)
        local source = entry_favorite_context(entry)
        local saved = source and get_item(item_key(source.url)) or nil
        local row = {
            title = shown,
            full_title = shown,
            hint = tostring(index),
            active = entry.current == true,
            value = index,
            actions_always_visible = true,
            actions_place = 'inside',
            actions = {
                {name = 'remove', icon = 'delete'},
            },
        }
        if source then
            table.insert(row.actions, 1, {
                name = 'favorite',
                icon = saved and saved.favorite and 'star' or 'star_border',
                active = saved and saved.favorite or false,
                tooltip = saved and saved.favorite and '取消收藏' or '收藏',
            })
        end
        items[#items + 1] = row
    end
    if #items == 0 then
        items[1] = {title = '暂无播放项', value = 'empty', selectable = false, muted = true, align = 'center'}
    end
    return items
end

local function favorite_items()
    local items = {}
    for _, item in ipairs(session_items) do
        if item.favorite then
            local note = trim(item.note)
            items[#items + 1] = {
                title = display_title(item),
                full_title = item.url,
                hint = note ~= '' and note or item.url,
                active = active_web_key == item.key or (favorite_navigation.active and favorite_navigation.current_key == item.key),
                keep_open = true,
                actions_always_visible = true,
                actions_place = 'inside',
                value = item.key,
                actions = {
                    {name = 'note', icon = 'edit_note', tooltip = note ~= '' and note or nil},
                    {name = 'favorite', icon = item.favorite and 'star' or 'star_border', active = item.favorite},
                },
            }
        end
    end
    if #items == 0 then
        items[1] = {title = '暂无收藏', value = 'empty', selectable = false, muted = true, align = 'center'}
    end
    return items
end

build_menu_data = function()
    local data = {
        type = MENU_TYPE,
        title = '',
        footnote = '',
        tabs = {
            {id = 'playlist', title = '播放列表'},
            {id = 'favorites', title = '收藏夹'},
        },
        active_tab = active_tab,
        on_tab = 'callback',
        on_move = 'callback',
        on_paste = 'callback',
        callback = {'live_playlist', 'menu-event'},
        keep_open = true,
        search_style = 'disabled',
        items = active_tab == 'favorites' and favorite_items() or playlist_items(),
    }
    return data
end

local function show_menu(anchor_cursor)
    local message = anchor_cursor and 'open-menu-cursor' or 'open-menu'
    mp.commandv('script-message-to', 'uosc', message, utils.format_json(build_menu_data()))
end

local function title_probe_args(item)
    local args = {COOKIE_BRIDGE, '--no-warnings', '--no-playlist', '--dump-single-json'}
    local raw_options = mp.get_property_native('ytdl-raw-options')
    if type(raw_options) == 'table' and is_text(raw_options.proxy) then
        table.insert(args, '--proxy')
        table.insert(args, raw_options.proxy)
    end
    table.insert(args, '--')
    table.insert(args, item.url)
    return args
end

local function process_title_refresh_queue()
    if title_refresh_running then return end
    local item = table.remove(title_refresh_queue, 1)
    if not item then return end
    title_refresh_running = true
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = title_probe_args(item),
    }, function(success, result)
        title_refresh_pending[item.key] = nil
        title_refresh_running = false
        if success and type(result) == 'table' and result.status == 0 then
            local title = title_from_ytdl_output(result.stdout, item.url)
            if update_item_title(item, title) then refresh_menu() end
        end
        mp.add_timeout(0, process_title_refresh_queue)
    end)
end

local function refresh_invalid_favorite_titles()
    for _, item in ipairs(session_items) do
        if item.favorite and not is_valid_live_title(item.title, item.url)
            and not title_refresh_pending[item.key] then
            title_refresh_pending[item.key] = true
            table.insert(title_refresh_queue, item)
        end
    end
    process_title_refresh_queue()
end

local function close_menu()
    mp.commandv('script-message-to', 'uosc', 'close-menu', MENU_TYPE)
end

local function playlist_entry()
    local position = mp.get_property_number('playlist-pos', -1)
    local playlist = mp.get_property_native('playlist') or {}
    return position >= 0 and playlist[position + 1] or nil
end

local function playlist_index_by_id(id)
    if id == nil then return nil end
    for index, entry in ipairs(mp.get_property_native('playlist') or {}) do
        if tostring(entry.id) == tostring(id) then return index - 1 end
    end
end

local function set_favorite_navigation_active(active)
    favorite_navigation.active = active == true
    mp.set_property_bool(FAVORITES_ACTIVE_PROPERTY, favorite_navigation.active)
end

local function cleanup_temporary_favorite_entry()
    local entry_id = favorite_navigation.cleanup_entry_id
    if not entry_id then return end
    local current = playlist_entry()
    if current and tostring(current.id) == tostring(entry_id) then return end
    local index = playlist_index_by_id(entry_id)
    if index ~= nil then mp.commandv('playlist-remove', tostring(index)) end
    favorite_navigation.cleanup_entry_id = nil
end

local function leave_favorite_navigation()
    if favorite_navigation.temporary_entry_id then
        favorite_navigation.cleanup_entry_id = favorite_navigation.temporary_entry_id
    end
    favorite_navigation.current_key = nil
    favorite_navigation.temporary_entry_id = nil
    favorite_navigation.pending = nil
    set_favorite_navigation_active(false)
    cleanup_temporary_favorite_entry()
end

local function favorite_entries()
    local entries = {}
    for _, item in ipairs(session_items) do
        if item.favorite then entries[#entries + 1] = item end
    end
    return entries
end

local function abandon_pending_favorite_load(message, resume)
    local pending = favorite_navigation.pending
    favorite_navigation.pending = nil
    if not pending then return end
    if pending.entry_id then
        local index = playlist_index_by_id(pending.entry_id)
        if index ~= nil then pcall(mp.commandv, 'playlist-remove', tostring(index)) end
    end
    if pending.was_active then
        favorite_navigation.current_key = pending.previous_key
        set_favorite_navigation_active(true)
    else
        leave_favorite_navigation()
    end
    if resume and pending.resume_entry_id then
        local index = playlist_index_by_id(pending.resume_entry_id)
        if index ~= nil then pcall(mp.commandv, 'playlist-play-index', tostring(index)) end
    end
    if message then mp.osd_message(message, 2) end
end

local function finish_pending_favorite_load()
    local pending = favorite_navigation.pending
    if not pending or not pending.entry_id then return end
    local current = playlist_entry()
    if not current then return end
    if tostring(current.id) ~= tostring(pending.entry_id) then
        -- A different entry finished loading while the favorite was still
        -- pending: the attempt was superseded.  Drop it without touching
        -- whatever is playing now, otherwise pending stays set forever and
        -- silently swallows every later favorite click.
        abandon_pending_favorite_load(nil, false)
        return
    end

    favorite_navigation.pending = nil
    favorite_navigation.current_key = pending.key
    favorite_navigation.temporary_entry_id = pending.entry_id
    set_favorite_navigation_active(true)
    if pending.previous_entry_id and tostring(pending.previous_entry_id) ~= tostring(pending.entry_id) then
        favorite_navigation.cleanup_entry_id = pending.previous_entry_id
        cleanup_temporary_favorite_entry()
    end
    refresh_menu()
end

local function wait_for_favorite_entry(pending)
    if favorite_navigation.pending ~= pending then return end
    local playlist = mp.get_property_native('playlist') or {}
    if #playlist >= pending.old_count + 1 then
        local entry = playlist[pending.old_count + 1]
        if entry and entry.id ~= nil then
            pending.entry_id = entry.id
            mp.commandv('playlist-play-index', tostring(pending.old_count))
            return
        end
    end
    if mp.get_time() >= pending.deadline then
        abandon_pending_favorite_load('打开收藏失败')
        return
    end
    mp.add_timeout(0.05, function() wait_for_favorite_entry(pending) end)
end

local function play_favorite(item)
    if not item or not item.favorite or favorite_navigation.pending then return end
    local current = playlist_entry()
    local pending = {
        key = item.key,
        old_count = mp.get_property_number('playlist-count', 0),
        previous_key = favorite_navigation.current_key,
        previous_entry_id = favorite_navigation.temporary_entry_id,
        resume_entry_id = current and current.id or nil,
        was_active = favorite_navigation.active,
        deadline = mp.get_time() + 5,
    }
    favorite_navigation.pending = pending
    favorite_navigation.current_key = item.key
    set_favorite_navigation_active(true)
    mp.commandv('loadfile', item.url, 'append')
    wait_for_favorite_entry(pending)
end

local function navigate_favorites(delta)
    if not favorite_navigation.active then
        mp.commandv(delta < 0 and 'playlist-prev' or 'playlist-next')
        return
    end
    if favorite_navigation.pending then return end

    local entries = favorite_entries()
    if #entries == 0 then
        leave_favorite_navigation()
        return
    end
    local current_index = nil
    for index, item in ipairs(entries) do
        if item.key == favorite_navigation.current_key then
            current_index = index
            break
        end
    end
    if not current_index then
        leave_favorite_navigation()
        return
    end

    local next_index = current_index + (delta < 0 and -1 or 1)
    if next_index < 1 or next_index > #entries then
        if mp.get_property_bool('loop-playlist', false) then
            next_index = next_index < 1 and #entries or 1
        else
            mp.osd_message(next_index < 1 and '已是收藏夹第一项' or '已是收藏夹最后一项', 2)
            return
        end
    end
    play_favorite(entries[next_index])
end

local function open_playlist(anchor_cursor)
    if mp.get_property('user-data/uosc/menu/type') == MENU_TYPE then
        close_menu()
        return
    end
    active_tab = 'playlist'
    show_menu(anchor_cursor)
end

local function move_favorite_item(from_index, to_index)
    local favorites = favorite_entries()
    if from_index == to_index or from_index < 1 or to_index < 1
        or from_index > #favorites or to_index > #favorites then
        return
    end

    local item = table.remove(favorites, from_index)
    table.insert(favorites, to_index, item)
    local favorite_positions = {}
    for index, session_item in ipairs(session_items) do
        if session_item.favorite then favorite_positions[#favorite_positions + 1] = index end
    end
    for index, favorite in ipairs(favorites) do
        session_items[favorite_positions[index]] = favorite
    end
    write_favorites()
end

local function move_playlist_item(from_index, to_index)
    if from_index == to_index then return end
    mp.commandv('playlist-move', tostring(from_index - 1), tostring(to_index - (to_index > from_index and 0 or 1)))
end

local function open_note_editor(item)
    note_edit_key = item.key
    local data = {
        type = NOTE_MENU_TYPE,
        title = '收藏备注',
        footnote = '',
        items = {
            {title = '按 Enter 保存，清空内容即可删除备注', value = 'hint', selectable = false, muted = true, align = 'center'},
        },
        search_style = 'palette',
        search_debounce = 'submit',
        search_suggestion = item.note or '',
        on_search = 'callback',
        callback = {'live_playlist', 'note-event'},
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(data))
end

local function update_note(query)
    local item = get_item(note_edit_key)
    note_edit_key = nil
    if not item then return end
    local previous = item.note
    item.note = trim(query)
    if item.favorite and not write_favorites() then
        item.note = previous
        mp.osd_message('保存收藏备注失败', 3)
        return
    end
    mp.add_timeout(0.02, function()
        active_tab = 'favorites'
        show_menu(false)
    end)
end

local function sync_web_item(url, kind, allow_media_title)
    local title = current_live_title(url, allow_media_title)
    local item = upsert_session_item(url, title, false, kind)
    if item then update_item_title(item, title) end
    return item
end

local function update_web_context(context)
    if not is_favoritable_web_context(context) then
        active_web_key = nil
        if favorite_navigation.active and not favorite_navigation.pending then leave_favorite_navigation() end
        refresh_menu()
        return
    end
    local item = sync_web_item(context.url, context.kind, false)
    active_web_key = item and item.key or nil
    if favorite_navigation.active and not favorite_navigation.pending
        and active_web_key ~= favorite_navigation.current_key then
        leave_favorite_navigation()
    end
    refresh_menu()
end

local function refresh_current_title(allow_media_title)
    local context = mp.get_property_native('user-data/web_source/context')
    if not is_favoritable_web_context(context) then return end
    local item = sync_web_item(context.url, context.kind, allow_media_title)
    active_web_key = item and item.key or nil
    refresh_menu()
end

local function menu_event(json)
    local event = utils.parse_json(json or '')
    if type(event) ~= 'table' then return end

    if event.type == 'tab' then
        active_tab = event.tab_id == 'favorites' and 'favorites' or 'playlist'
        refresh_menu()
        if active_tab == 'favorites' then mp.add_timeout(0, refresh_invalid_favorite_titles) end
        return
    end

    if event.type == 'move' then
        if active_tab == 'favorites' then
            move_favorite_item(event.from_index, event.to_index)
        else
            move_playlist_item(event.from_index, event.to_index)
        end
        mp.add_timeout(0, refresh_menu)
        return
    end

    if event.type == 'paste' and active_tab == 'playlist' and is_text(event.value) then
        mp.commandv('loadfile', event.value, 'append')
        mp.add_timeout(0, refresh_menu)
        return
    end

    if event.type ~= 'activate' then return end
    if active_tab == 'playlist' then
        local index = tonumber(event.value)
        if not index then return end
        if event.action == 'favorite' then
            local entry = playlist_entry_at(index)
            local source = entry_favorite_context(entry)
            if not source then return end
            local title = entry and entry.current and current_live_title(source.url, true)
                or entry and trim(entry.title) or ''
            local item = upsert_session_item(source.url, title, false, source.kind)
            if not item then return end
            local previous = item.favorite
            item.favorite = not previous
            if not write_favorites() then
                item.favorite = previous
                mp.osd_message('保存收藏失败', 3)
            elseif not item.favorite and favorite_navigation.current_key == item.key then
                leave_favorite_navigation()
            end
            refresh_menu()
        elseif event.action == 'remove' then
            local entry = playlist_entry_at(index)
            if entry and favorite_navigation.temporary_entry_id
                and tostring(entry.id) == tostring(favorite_navigation.temporary_entry_id) then
                leave_favorite_navigation()
            end
            mp.commandv('playlist-remove', tostring(index - 1))
            mp.add_timeout(0, refresh_menu)
        elseif not event.action then
            leave_favorite_navigation()
            mp.commandv('set', 'playlist-pos-1', tostring(index))
            close_menu()
        end
        return
    end

    local item = get_item(event.value)
    if not item then return end
    if event.action == 'note' then
        open_note_editor(item)
    elseif event.action == 'favorite' then
        local previous = item.favorite
        item.favorite = not previous
        if not write_favorites() then
            item.favorite = previous
            mp.osd_message('保存收藏失败', 3)
        elseif not item.favorite and favorite_navigation.current_key == item.key then
            leave_favorite_navigation()
        end
        refresh_menu()
    elseif not event.action then
        if item.favorite then
            play_favorite(item)
        else
            leave_favorite_navigation()
            mp.commandv('loadfile', item.url, 'append-play')
        end
        close_menu()
    end
end

local function note_event(json)
    local event = utils.parse_json(json or '')
    if type(event) == 'table' and event.type == 'search' then update_note(event.query) end
end

load_favorites()

mp.observe_property('user-data/web_source/context', 'native', function(_, context)
    update_web_context(context)
end)
mp.observe_property('media-title', 'string', function()
    mp.add_timeout(0, function() refresh_current_title(true) end)
end)
mp.observe_property('user-data/mpv/ytdl/json-subprocess-result', 'native', function()
    mp.add_timeout(0, function() refresh_current_title(false) end)
end)
mp.register_event('file-loaded', function()
    local pending = favorite_navigation.pending
    local current = playlist_entry()
    if pending and pending.entry_id and current
        and tostring(current.id) == tostring(pending.entry_id) then
        -- Mark success before the deferred finish runs so a same-tick
        -- end-file is not mistaken for a failed load.
        pending.loaded = true
    end
    mp.add_timeout(0, function()
        finish_pending_favorite_load()
        cleanup_temporary_favorite_entry()
        refresh_current_title(false)
    end)
end)

mp.register_event('end-file', function(event)
    local pending = favorite_navigation.pending
    if not pending or not pending.entry_id or pending.loaded then return end
    local entry_id = type(event) == 'table' and event.playlist_entry_id or nil
    if not entry_id or tostring(entry_id) ~= tostring(pending.entry_id) then return end

    -- The pending favorite entry ended before it could load (e.g. the live
    -- room is offline and yt-dlp finds no formats).  Drop the dead entry,
    -- restore the previous navigation state and resume what was playing
    -- before the click.  Without this, pending stays set forever and every
    -- later favorite click is silently ignored.
    local failed = type(event) == 'table' and event.reason == 'error'
    abandon_pending_favorite_load(failed and '打开收藏失败' or nil, failed)
end)
mp.register_event('shutdown', function()
    mp.set_property_bool(FAVORITES_ACTIVE_PROPERTY, false)
end)

mp.register_script_message('menu-event', menu_event)
mp.register_script_message('note-event', note_event)
mp.add_key_binding(nil, 'open', function() open_playlist(false) end)
mp.add_key_binding(nil, 'open-cursor', function() open_playlist(true) end)
mp.add_key_binding(nil, 'favorite-prev', function() navigate_favorites(-1) end)
mp.add_key_binding(nil, 'favorite-next', function() navigate_favorites(1) end)
