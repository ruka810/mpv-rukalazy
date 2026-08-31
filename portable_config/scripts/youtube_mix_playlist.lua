local mp = require 'mp'

-- YouTube's RD playlists are generated radios.  yt-dlp follows their
-- continuations indefinitely, while the YouTube page exposes the first 25
-- recommendations as the current radio queue.
local RADIO_QUEUE_SIZE = '25'
local restore_value = nil

local function is_youtube_radio(url)
    if type(url) ~= 'string' then return false end
    local host = url:match('^https?://([^/%?]+)')
    if not host or not (host:find('youtube%.com', 1, false) or host:find('youtu%.be', 1, false)) then
        return false
    end
    local list_id = url:match('[?&]list=([^&]+)')
    return list_id ~= nil and list_id:match('^RD') ~= nil
end

local function source_url()
    return mp.get_property('stream-open-filename') or mp.get_property('path') or ''
end

-- This runs immediately before ytdl_hook.  The option is restored after its
-- command line is built, so ordinary playlists remain unbounded.
mp.add_hook('on_load', 9, function()
    local options = mp.get_property_native('ytdl-raw-options') or {}
    restore_value = options['playlist-end']
    if is_youtube_radio(source_url()) then
        options['playlist-end'] = RADIO_QUEUE_SIZE
        mp.msg.info('YouTube radio: importing the 25-item page queue')
    else
        options['playlist-end'] = nil
    end
    mp.set_property_native('ytdl-raw-options', options)
end)

mp.add_hook('on_load', 11, function()
    local options = mp.get_property_native('ytdl-raw-options') or {}
    options['playlist-end'] = restore_value
    restore_value = nil
    mp.set_property_native('ytdl-raw-options', options)
end)
