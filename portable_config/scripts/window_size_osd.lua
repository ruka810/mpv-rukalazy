--[[
	window_size_osd.lua
	调整窗口大小时，在左上角短暂显示当前窗口像素尺寸（形如 1320x865）。

	1) 显示时机：窗口尺寸一旦发生变化就显示，覆盖
	   鼠标拖拽窗口边缘、Ctrl+滚轮缩放、Alt+1~4 按屏幕面积缩放、系统 Win+方向键/最大化等。
	   （全屏状态下不显示，也不会覆盖「已切换全屏/窗口」的提示）
	2) 手动微调（按住可连续调整）：
	   Ctrl+Shift+右 / 左   窗口变宽 / 变窄 20 像素（高度按当前比例同步变化）
	   Ctrl+Shift+上 / 下   窗口变高 / 变矮 20 像素（宽度按当前比例同步变化）

	说明：
	 - 尺寸读取自 osd-dimensions/w|h，即窗口内容区像素，与 --geometry 单位一致
	 - 调整通过 --geometry 设置，只给尺寸时 mpv 会保持窗口中心不变
	 - 可用 --script-opts=window_size_osd-step=20 修改像素步进，
	   window_size_osd-duration=1.5 修改 OSD 停留时长
]]

local mp = require "mp"
mp.options = require "mp.options"

local opts = {
	step = 20,      -- 快捷键每次调整的像素
	duration = 1.5, -- OSD 停留秒数
}
mp.options.read_options(opts, 'window_size_osd')

local MIN_W, MIN_H = 200, 120 -- 窗口最小宽高，避免缩到不可用

local last_size = nil          -- 上一次记录的尺寸字符串
local fs_changed_at = -1e9     -- 上一次全屏状态变化的时刻，用于抑制切换瞬间的显示

local function read_size()
	local w = mp.get_property_number('osd-dimensions/w', 0) or 0
	local h = mp.get_property_number('osd-dimensions/h', 0) or 0
	if w <= 0 or h <= 0 then return nil end
	return w, h
end

local function show(w, h)
	mp.osd_message(string.format('%dx%d', w, h), opts.duration)
end

local function on_size_change()
	local w, h = read_size()
	if not w then
		last_size = nil -- 窗口尚未创建/正在重建，等下一次有效尺寸
		return
	end
	local size = string.format('%dx%d', w, h)
	if last_size == nil then
		last_size = size -- 首次有效尺寸（启动/窗口重建）只记录，不显示
		return
	end
	if size == last_size then return end
	last_size = size
	if mp.get_property_bool('fullscreen', false) then return end
	if mp.get_time() - fs_changed_at < 0.6 then return end
	show(w, h)
end

-- 以当前窗口宽高为基准按像素步进调整；另一方向按比例同步，保持窗口形状不变
local function resize(dw, dh)
	local w, h = read_size()
	if not w then return end
	local nw, nh
	if dw ~= 0 then
		nw = math.max(MIN_W, w + dw)
		nh = math.max(MIN_H, math.floor(h * nw / w + 0.5))
	else
		nh = math.max(MIN_H, h + dh)
		nw = math.max(MIN_W, math.floor(w * nh / h + 0.5))
	end
	if nw == w and nh == h then
		show(w, h) -- 已到最小尺寸限制，仍然给出反馈
		return
	end
	mp.set_property('geometry', string.format('%dx%d', nw, nh))
end

mp.observe_property('osd-dimensions/w', 'number', on_size_change)
mp.observe_property('osd-dimensions/h', 'number', on_size_change)
mp.observe_property('fullscreen', 'bool', function()
	fs_changed_at = mp.get_time()
	last_size = nil -- 全屏切换后重新记录，切回窗口时不会误显示
end)

mp.add_key_binding('Ctrl+Shift+RIGHT', 'wider', function() resize(opts.step, 0) end, { repeatable = true })
mp.add_key_binding('Ctrl+Shift+LEFT', 'narrower', function() resize(-opts.step, 0) end, { repeatable = true })
mp.add_key_binding('Ctrl+Shift+UP', 'taller', function() resize(0, opts.step) end, { repeatable = true })
mp.add_key_binding('Ctrl+Shift+DOWN', 'shorter', function() resize(0, -opts.step) end, { repeatable = true })
