local mp = require 'mp'

local lyric_file = '~~/_cache/embedded-lyrics.srt'
local last_lyrics = nil
local schedule_id = 0

local function trim(value)
    return (tostring(value):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function normalize_key(key)
    return tostring(key):lower():gsub('[^%w]', '')
end

local function find_lyrics()
    local metadata = mp.get_property_native('metadata')
    if type(metadata) ~= 'table' then return nil end

    local synced, plain
    for key, value in pairs(metadata) do
        local actual_key, actual_value = key, value
        if type(value) == 'table' then
            actual_key = value.key or value.name or key
            actual_value = value.value or value.text or value.data
        end

        if type(actual_value) == 'string' and trim(actual_value) ~= '' then
            local normalized = normalize_key(actual_key)
            if normalized == 'lrc' or normalized == 'lyr' or normalized == 'syncedlyrics' or normalized == 'timedlyrics' then
                synced = actual_value
            elseif normalized == 'lyrics' or normalized == 'unsyncedlyrics' or normalized == 'unsyncedtext' then
                plain = actual_value
            elseif normalized:find('lyrics', 1, true) then
                plain = plain or actual_value
            end
        end
    end
    return synced or plain
end

local function srt_time(seconds)
    seconds = math.max(0, seconds)
    local millis = math.floor(seconds * 1000 + 0.5)
    local hours = math.floor(millis / 3600000)
    millis = millis % 3600000
    local minutes = math.floor(millis / 60000)
    millis = millis % 60000
    local secs = math.floor(millis / 1000)
    millis = millis % 1000
    return string.format('%02d:%02d:%02d,%03d', hours, minutes, secs, millis)
end

local function make_srt(lyrics)
    local entries = {}
    for line in lyrics:gmatch('[^\r\n]+') do
        local times = {}
        for minute, second in line:gmatch('%[(%d+):(%d%d%.?%d*)%]') do
            times[#times + 1] = tonumber(minute) * 60 + tonumber(second)
        end
        if #times > 0 then
            local text = trim((line:gsub('%b[]', '')))
            if text ~= '' then
                for _, timestamp in ipairs(times) do
                    entries[#entries + 1] = {time = timestamp, text = text}
                end
            end
        end
    end

    if #entries == 0 then
        local duration = mp.get_property_number('duration', 0)
        if duration <= 0 then duration = 86400 end
        return '1\n' .. srt_time(0) .. ' --> ' .. srt_time(duration) .. '\n' .. lyrics .. '\n\n'
    end

    table.sort(entries, function(a, b) return a.time < b.time end)
    local duration = mp.get_property_number('duration', 0)
    local result = {}
    for index, entry in ipairs(entries) do
        local next_entry = entries[index + 1]
        local finish = next_entry and next_entry.time - 0.01 or duration
        if not finish or finish <= entry.time then finish = entry.time + 0.1 end
        result[#result + 1] = tostring(index)
        result[#result + 1] = srt_time(entry.time) .. ' --> ' .. srt_time(finish)
        result[#result + 1] = entry.text
        result[#result + 1] = ''
    end
    return table.concat(result, '\n')
end

local function load_lyrics()
    local lyrics = find_lyrics()
    if not lyrics or lyrics == last_lyrics then return end
    last_lyrics = lyrics

    local path = mp.command_native({'expand-path', lyric_file})
    local file, error_message = io.open(path, 'w')
    if not file then
        mp.msg.warn('无法写入内嵌歌词字幕: ' .. tostring(error_message))
        return
    end
    file:write(make_srt(lyrics))
    file:close()
    mp.commandv('sub-add', path, 'select', 'Embedded lyrics')
end

local function schedule_load()
    schedule_id = schedule_id + 1
    local current_id = schedule_id
    mp.add_timeout(0.2, function()
        if current_id == schedule_id then load_lyrics() end
    end)
end

mp.register_event('file-loaded', function()
    last_lyrics = nil
    schedule_load()
end)
mp.observe_property('metadata', 'native', schedule_load)
