local mp = require 'mp'

-- The title preloaders create M3U entries with this fragment.  Keep yt-dlp
-- from expanding the selected entry again, which would replace the titled M3U
-- playlist with extractor entries that have not had their titles resolved yet.
local MARKER = 'mpv-preloaded-playlist'
local restore_state = nil

local function has_marker(path)
    return type(path) == 'string' and path:find(MARKER, 1, true) ~= nil
end

-- Bilibili Live exposes every CDN/quality route as a playlist when
-- --yes-playlist is present.  mpv then mistakes those alternate URLs for
-- actual video tracks.  A live room must resolve to one selected stream; the
-- quality picker reloads the same page with the desired format selector.
local function is_bilibili_live(path)
    return type(path) == 'string'
        and path:match('^https?://live%.bilibili%.com/%d+') ~= nil
end

local function restore_playlist_options()
    if not restore_state then return end

    local options = mp.get_property_native('ytdl-raw-options') or {}
    options['yes-playlist'] = restore_state.yes_playlist
    options['no-playlist'] = restore_state.no_playlist
    mp.set_property_native('ytdl-raw-options', options)
    restore_state = nil
end

local function arm_no_playlist()
    local source_path = mp.get_property('stream-open-filename') or ''
    if not has_marker(source_path) then source_path = mp.get_property('path') or '' end
    if not has_marker(source_path) and not is_bilibili_live(source_path) then return end

    restore_playlist_options()
    local options = mp.get_property_native('ytdl-raw-options') or {}
    restore_state = {
        yes_playlist = options['yes-playlist'],
        no_playlist = options['no-playlist'],
    }
    options['yes-playlist'] = nil
    options['no-playlist'] = ''
    mp.set_property_native('ytdl-raw-options', options)
end

-- ytdl_hook runs at priority 10. Depending on its try_ytdl_first setting,
-- yt-dlp runs during on_load or after a direct URL open fails. Cover both
-- phases and restore at priority 11 after its subprocess arguments are built.
mp.add_hook('on_load', 9, arm_no_playlist)
mp.add_hook('on_load', 11, restore_playlist_options)
mp.add_hook('on_load_fail', 9, arm_no_playlist)
mp.add_hook('on_load_fail', 11, restore_playlist_options)
mp.register_event('file-loaded', restore_playlist_options)
mp.register_event('end-file', restore_playlist_options)
mp.register_event('shutdown', restore_playlist_options)
