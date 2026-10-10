-- bilibili_parse_bridge.lua —— 确保本地桥在运行。
--
-- 浏览器侧的「在 mpv 播放」油猴按钮会把解析直链 POST 到 127.0.0.1:8322，
-- 由 bilibili_parse_bridge 新开一个 mpv 窗口播放。桥必须常驻：
-- 用户在浏览器点击按钮时 mpv 可能还没启动，所以这里只在 mpv 启动时
-- detached 拉起一次，不随 mpv 退出而停止（双击 tools/bilibili_parse_bridge.bat
-- 也可以手动启动）。桥自带单实例保护，重复启动无害。

local utils = require 'mp.utils'

local bridge_py = mp.command_native({ 'expand-path', '~~/tools/bilibili_parse_bridge.py' })
local pythonw = mp.command_native({ 'expand-path', '~~/../pythonw.exe' })

local function ensure_bridge()
    if not utils.file_info(bridge_py) or not utils.file_info(pythonw) then
        mp.msg.verbose('[bilibili_parse_bridge] 组件不可用，跳过自动拉起')
        return
    end
    local ok, err = pcall(utils.subprocess_detached, {
        args = { pythonw, bridge_py },
        playback_only = false,
        cancellable = false,
    })
    if not ok then
        mp.msg.warn('[bilibili_parse_bridge] 启动失败: ' .. tostring(err))
    end
end

mp.add_timeout(0, ensure_bridge)
