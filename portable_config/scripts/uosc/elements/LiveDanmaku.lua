local Element = require('elements/Element')

---@class LiveDanmaku : Element
local LiveDanmaku = class(Element)

local function clamp_value(minimum, value, maximum)
	return math.max(minimum, math.min(value, maximum))
end

local function color_to_ass(color)
	if type(color) == 'number' then
		local red = math.floor(color / 65536) % 256
		local green = math.floor(color / 256) % 256
		local blue = color % 256
		return string.format('%02X%02X%02X', blue, green, red), red, green, blue
	end
	local hex = tostring(color or ''):gsub('#', '')
	if #hex == 6 and hex:match('^[%x]+$') then
		local red = tonumber(hex:sub(1, 2), 16) or 42
		local green = tonumber(hex:sub(3, 4), 16) or 96
		local blue = tonumber(hex:sub(5, 6), 16) or 178
		return string.format('%02X%02X%02X', blue, green, red), red, green, blue
	end
	return 'FFFFFF', 255, 255, 255
end

local function truncate_text(value, max_width, opts)
	value = tostring(value or ''):gsub('[\r\n]+', ' ')
	if text_width(value, opts) <= max_width then return ass_escape(value) end
	local suffix = '…'
	local output, index = {}, 1
	while index <= #value do
		local length = utf8_char_bytes(value, index)
		local candidate = table.concat(output) .. value:sub(index, index + length - 1) .. suffix
		if text_width(candidate, opts) > max_width then break end
		output[#output + 1] = value:sub(index, index + length - 1)
		index = index + length
	end
	return ass_escape(table.concat(output) .. suffix)
end

function LiveDanmaku:new() return Class.new(self) --[[@as LiveDanmaku]] end

function LiveDanmaku:init()
	Element.init(self, 'live_danmaku', {render_order = 5})
	self.normal = {}
	self.lane_last = {}
	self.cards = {}
	self.timer = mp.add_periodic_timer(1 / 30, function()
		if #self.normal > 0 or #self.cards > 0 then request_render() end
	end)
	self:register_disposer(function() self.timer:kill() end)
end

function LiveDanmaku:get_visibility()
	return (#self.normal > 0 or #self.cards > 0) and 1 or 0
end

function LiveDanmaku:font_size()
	return math.max(20, round(50 * display.height / 1080))
end

function LiveDanmaku:lane_count(font_size)
	local line_height = math.max(font_size * 1.2, 1)
	return math.max(1, math.floor((display.height * 0.25) / line_height)), line_height
end

function LiveDanmaku:prune(now)
	for index = #self.normal, 1, -1 do
		if self.normal[index].expires_at <= now then table.remove(self.normal, index) end
	end
	for index = #self.cards, 1, -1 do
		if self.cards[index].expires_at <= now then table.remove(self.cards, index) end
	end
end

function LiveDanmaku:add_normal(data)
	local now = mp.get_time()
	self:prune(now)
	local font_size = self:font_size()
	local opts = {size = font_size, font = 'Microsoft YaHei', bold = false}
	local width = math.max(1, text_width(tostring(data.text or ''), opts))
	local lanes = self:lane_count(font_size)
	local duration = 8
	local lane = nil
	for index = 1, lanes do
		local previous = self.lane_last[index]
		if not previous then
			lane = index
			break
		end
		-- The next message starts on the right.  It can enter once the previous
		-- message's tail has moved left by a small gap, preventing overlap while
		-- keeping a much denser flow than reserving a lane for its full duration.
		local safe_delay = previous.width * previous.duration / (display.width + previous.width) + 0.12
		if now - previous.started_at >= safe_delay then
			lane = index
			break
		end
	end
	if not lane then return end
	local color = color_to_ass(data.color)
	local message = {
		text = tostring(data.text or ''),
		color = color,
		width = width,
		lane = lane,
		started_at = now,
		expires_at = now + duration,
		duration = duration,
	}
	self.normal[#self.normal + 1] = message
	self.lane_last[lane] = message
	request_render()
end

function LiveDanmaku:add_superchat(data)
	local now = mp.get_time()
	self:prune(now)
	local duration = tonumber(data.duration) or 30
	local color, red, green, blue = color_to_ass(data.color)
	self.cards[#self.cards + 1] = {
		id = tostring(data.id or (now .. '-' .. #self.cards)),
		user = tostring(data.user or '醒目留言'),
		text = tostring(data.text or ''),
		color = color,
		red = red,
		green = green,
		blue = blue,
		expires_at = now + clamp_value(1, duration, 3600),
	}
	request_render()
end

function LiveDanmaku:close_superchat(id)
	for index = #self.cards, 1, -1 do
		if self.cards[index].id == tostring(id) then table.remove(self.cards, index) end
	end
	request_render()
end

function LiveDanmaku:clear_normal()
	self.normal, self.lane_last = {}, {}
	request_render()
end

function LiveDanmaku:clear_superchat()
	self.cards = {}
	request_render()
end

function LiveDanmaku:render()
	local now = mp.get_time()
	self:prune(now)
	if #self.normal == 0 and #self.cards == 0 then return end

	local ass = assdraw.ass_new()
	local font_size = self:font_size()
	local lane_count, line_height = self:lane_count(font_size)
	local text_opts = {
		size = font_size,
		font = 'Microsoft YaHei',
		color = 'FFFFFF',
		border = math.max(1, font_size / 25),
		border_color = '000000',
		opacity = 0.5,
	}
	for _, message in ipairs(self.normal) do
		local progress = clamp_value(0, (now - message.started_at) / message.duration, 1)
		local x = display.width - (display.width + message.width) * progress
		local y = font_size * 0.65 + (message.lane - 1) * line_height
		if message.lane <= lane_count then
			text_opts.color = message.color
			ass:txt(x, y, 4, ass_escape(message.text), text_opts)
		end
	end

	local scale = math.max(0.75, display.height / 1080)
	local margin = round(12 * scale) + Elements:v('window_border', 'size', 0)
	local width = math.min(round(display.width * 0.42), math.max(round(280 * scale), round(display.width * 0.22)))
	local card_font = math.max(16, round(20 * scale))
	local user_font = math.max(14, round(16 * scale))
	local card_gap = round(8 * scale)
	local y = margin + Elements:v('top_bar', 'size', 0)
	local max_y = (Elements:v('controls', 'ay', display.height) or display.height) - margin
	for index, card in ipairs(self.cards) do
		local card_height = round(76 * scale)
		if y + card_height > max_y then break end
		local ax, bx = margin, margin + width
		local ay, by = y, y + card_height
		local background = card.color
		local brightness = card.red * 0.299 + card.green * 0.587 + card.blue * 0.114
		local foreground = brightness > 155 and '000000' or 'FFFFFF'
		ass:rect(ax, ay, bx, by, {color = background, opacity = 0.92, radius = state.radius})
		local close_size = math.max(32, round(40 * scale))
		local close_ax, close_ay = bx - close_size - round(8 * scale), ay + round(7 * scale)
		local close_rect = {ax = close_ax, ay = close_ay, bx = close_ax + close_size, by = close_ay + close_size}
		cursor:zone('primary_down', close_rect, self:create_action(function() self:close_superchat(card.id) end))
		ass:icon(close_ax + close_size / 2, close_ay + close_size / 2, close_size, 'close', {color = foreground, opacity = 0.9})
		ass:txt(ax + round(12 * scale), ay + round(20 * scale), 4,
			truncate_text(card.user, width - close_size - round(34 * scale), {size = user_font, bold = true}),
			{size = user_font, color = foreground, bold = true, opacity = 1})
		ass:txt(ax + round(12 * scale), ay + round(52 * scale), 4,
			truncate_text(card.text, width - round(24 * scale), {size = card_font}),
			{size = card_font, color = foreground, opacity = 1})
		y = by + card_gap
	end

	return ass
end

return LiveDanmaku
