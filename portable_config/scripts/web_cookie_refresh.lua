local mp = require 'mp'
local utils = require 'mp.utils'

-- Cookie refresh used to close Chrome and replace a Netscape cookie file.
-- The active path is now the Chrome extension bridge: all cookies stay in
-- Chrome/bridge memory and this script only exposes a harmless diagnostic for
-- legacy menu bindings.

local bridge = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/publish_v13/mpv-cookie-bridge.exe' })
local node = 'E:/nodejs/node.exe'
local pot_server = mp.command_native({ 'expand-path', '~~/tools/chrome_cookie_bridge/pot_provider_src/bgutil-ytdlp-pot-provider-1.3.1/server/build/main.js' })
math.randomseed(os.time() + math.floor(mp.get_time() * 1000000))
local session_id = string.format('%d-%d', os.time(), math.random(1, 0x7fffffff))
local shutting_down = false
local status_request = nil
local status_serial = 0
local temp_dir = os.getenv('TEMP') or os.getenv('TMP') or mp.command_native({ 'expand-path', '~~/cache' })

local function run_bridge_detached(args)
    if shutting_down or not utils.file_info(bridge) then return end
    pcall(utils.subprocess_detached, { args = args })
end

local function stop_status_request()
    if status_request and status_request.timer then status_request.timer:kill() end
    status_request = nil
end

local function ps_quote(value)
    return "'" .. value:gsub("'", "''") .. "'"
end

local function read_file(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local data = file:read('*all')
    file:close()
    return data
end

local function show_status(data)
    if data and data.bilibiliCached and data.youtubeCached then
        mp.osd_message('B站和 YouTube Cookie 已缓存；关闭 Chrome 不影响本次 mpv 会话', 4)
    elseif data and data.connected then
        mp.osd_message('Chrome Cookie Bridge 已连接，正在缓存 B站和 YouTube Cookie', 3)
    else
        mp.osd_message('Chrome Cookie Bridge 未连接，且没有完整内存 Cookie 缓存', 4)
    end
end

-- Start the service as mpv starts, rather than waiting for a first online
-- video. Once both jars have arrived, they remain in the bridge's memory if
-- Chrome is closed later in this mpv session.
local function warm_cache()
    if not utils.file_info(bridge) then return end
    run_bridge_detached({ bridge, '--warm' })
end

local function start_pot_server()
    if not utils.file_info(node) or not utils.file_info(pot_server) then
        mp.msg.verbose('[web_cookie_refresh] Local YouTube PO-token server is unavailable')
        return
    end
    -- The server is loopback-only and exits immediately if another mpv
    -- session already owns the port.  Starting it detached avoids delaying
    -- mpv startup while keeping normal playback from spawning Node per URL.
    pcall(utils.subprocess_detached, {
        args = { node, pot_server, '--port', '4416' },
        playback_only = false,
        cancellable = false,
    })
end

local function open_session()
    if not utils.file_info(bridge) then return end
    run_bridge_detached({ bridge, '--session-open', session_id })
end

local function report_status()
    if not utils.file_info(bridge) then
        mp.osd_message('Chrome Cookie Bridge 组件不可用', 3)
        return
    end
    stop_status_request()
    status_serial = status_serial + 1
    local serial = status_serial
    local output = utils.join_path(temp_dir, string.format('mpv-cookie-status-%s-%d.json', session_id, serial))
    os.remove(output)
    local command = '$output = (& ' .. ps_quote(bridge) .. ' --status 2>&1 | Out-String); '
        .. '[System.IO.File]::WriteAllText(' .. ps_quote(output) .. ', $output)'
    pcall(utils.subprocess_detached, {
        args = { 'powershell.exe', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', command },
    })

    local started = mp.get_time()
    local request = { output = output }
    status_request = request
    request.timer = mp.add_periodic_timer(0.1, function()
        if shutting_down or serial ~= status_serial or status_request ~= request then
            request.timer:kill()
            return
        end
        local output_data = read_file(output)
        if output_data and #output_data > 0 then
            request.timer:kill()
            status_request = nil
            os.remove(output)
            show_status(utils.parse_json(output_data))
            return
        end
        if mp.get_time() - started >= 10 then
            request.timer:kill()
            status_request = nil
            mp.osd_message('Chrome Cookie Bridge 状态查询超时', 3)
        end
    end)
end

mp.add_key_binding(nil, 'request', report_status)
mp.register_script_message('request', report_status)
mp.add_timeout(0, function()
    if shutting_down then return end
    open_session()
    start_pot_server()
    warm_cache()
end)
mp.register_event('shutdown', function()
    shutting_down = true
    status_serial = status_serial + 1
    stop_status_request()
    -- The service is shared by all active mpv windows.  Releasing this window
    -- must not clear the memory Cookie jars while another mpv still uses them.
    pcall(utils.subprocess_detached, {
        args = { bridge, '--session-close', session_id }, playback_only = false, cancellable = false,
    })
end)
