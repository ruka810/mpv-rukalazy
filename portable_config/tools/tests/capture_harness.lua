-- Exercise the production key callbacks, replacing only the save dialog and playback state.
local utils = require 'mp.utils'
local file = assert(io.open(os.getenv('CAPTURE_TEST_JOB'), 'rb'))
local job = utils.parse_json(file:read('*a'))
file:close()
local original_native, original_async = mp.command_native, mp.command_native_async
local original_get, original_number, original_property = mp.get_property_native, mp.get_property_number, mp.get_property
local callbacks, position = {}, job.start
mp.command_native = function(command, ...)
    if command[1] == 'expand-path' and command[2]:sub(1, 3) == '~~/' then
        return job.config_dir .. '/' .. command[2]:sub(4)
    end
    return original_native(command, ...)
end
mp.get_property_native = function(name, ...)
    if name == 'options/vf' then return job.vf or {} end
    if name == 'options/glsl-shaders' then return job.shaders or {} end
    if name == 'track-list' then return job.tracks or {} end
    return original_get(name, ...)
end
mp.get_property = function(name, ...)
    if name == 'path' then return job.source end
    return original_property(name, ...)
end
mp.get_property_number = function(name, ...)
    if name == 'time-pos' then return position end
    return original_number(name, ...)
end
mp.get_property_osd = function() return tostring(position) end
mp.command_native_async = function(command, callback)
    if not job.real_dialog and command.args and command.args[1] == 'powershell' then
        callback(true, {status = 0, stdout = job.output or ''})
        return
    end
    return original_async(command, callback)
end
mp.add_key_binding = function(_, name, callback) callbacks[name] = callback end
mp.osd_message = function(message)
    print(message)
    if message:find('已导出') then
        original_native({'quit', 0})
    elseif message:find('失败') or message:find('Unsupported') or message:find('Cannot') then
        original_native({'quit', 2})
    end
end
dofile(job.script)
mp.add_timeout(0.1, function()
    callbacks['capture-start-clip-rendered']()
    position = job.finish
    callbacks['capture-finish-clip-rendered']()
    if not job.output then original_native({'quit', 0}) end
end)
mp.add_timeout(180, function() original_native({'quit', 3}) end)
