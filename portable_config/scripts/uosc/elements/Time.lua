local Element = require('elements/Element')

---@class Time : Element
local Time = class(Element)

local LIVE_SEND_AVAILABLE = 'user-data/bilibili_danmaku/live-send-available'
local LIVE_SEND_SOURCE = 'user-data/bilibili_danmaku/live-send-source'

function Time:new(props) return Class.new(self, props) --[[@as Time]] end

function Time:init(props)
	Element.init(self, 'time', props)
	self.font_size = 1
	self.editing = false
	self.input = ''
	self.cursor_index = 0
	self.select_all = false
	self.cancel_click_listener = nil
	self.restore_edit_ime = false
	self.danmaku = false
	self.danmaku_input = ''
	self.danmaku_cursor_index = 0
	self.danmaku_sending = false
	self.danmaku_error = nil
	self.danmaku_request_id = 0
	self.danmaku_active_request_id = nil
	self.restore_danmaku_ime = false
	self.danmaku_draft = ''
	self.danmaku_draft_source = nil
	self.live_danmaku_source = mp.get_property(LIVE_SEND_SOURCE) or ''
	self.danmaku_pointer_down_listener = nil
	self.danmaku_pointer_up_listener = nil
	self.danmaku_pointer_capture_pending = false
	self.danmaku_pointer_capture_timeout = nil
	self.layout_key = nil
	self.layout_refresh_pending = false

	self:observe_mp_property(LIVE_SEND_AVAILABLE, 'bool', function(_, available)
		if not available then
			self:clear_danmaku_draft()
			if self.danmaku then self:end_danmaku() end
		end
	end)
	self:observe_mp_property(LIVE_SEND_SOURCE, 'string', function(_, source)
		source = source or ''
		if source == self.live_danmaku_source then return end
		self.live_danmaku_source = source
		self:clear_danmaku_draft()
		if self.danmaku then self:end_danmaku() end
	end)
end

function Time:destroy()
	self:end_edit()
	self:end_danmaku()
	Element.destroy(self)
end

function Time:on_coordinates()
	self.font_size = round((self.by - self.ay) * 0.78 * options.font_scale)
	self:queue_layout_refresh()
end

function Time:on_options()
	self:on_coordinates()
	self.layout_key = nil
end

function Time:on_prop_is_idle()
	if state.is_idle then
		self:end_edit()
		self:end_danmaku()
	end
	self:queue_layout_refresh()
end

function Time:on_prop_duration()
	if (not state.duration or state.duration <= 0) and self.editing then self:end_edit() end
	self:queue_layout_refresh()
end

function Time:on_prop_time() self:queue_layout_refresh() end

function Time:get_visibility()
	return (self.editing or self.danmaku) and 1 or Element.get_visibility(self)
end

function Time:keep_visible() return self.danmaku end

function Time:can_seek()
	return state.time ~= nil and state.duration ~= nil and state.duration > 0 and not state.is_idle
end

function Time:get_display_text()
	if self:can_seek() then
		return format_time(state.time, state.duration) .. ' / ' .. format_time(state.duration, state.duration)
	elseif state.time ~= nil and not state.is_idle then
		return format_time(state.time, state.time) .. ' / 直播'
	end
	return '--:-- / --:--'
end

function Time:get_layout_ratios(size)
	if self.danmaku then return 15, 8 end

	local font_size = round(size * 0.78 * options.font_scale)
	local opts = {size = font_size, border = options.text_border * state.scale}
	local text = timestamp_zero_rep(self:get_display_text())
	local padding = round(font_size * 0.45)
	local width = text_width(text, opts) + padding * 2 + state.scale * 2
	local ratio = math.max(3.5, width / math.max(1, size))
	return ratio, ratio
end

function Time:queue_layout_refresh()
	if self.layout_refresh_pending or self.destroyed then return end
	self.layout_refresh_pending = true
	mp.add_timeout(0, self:create_action(function()
		self.layout_refresh_pending = false
		local size = math.max(1, self.by - self.ay)
		local ratio, ratio_min = self:get_layout_ratios(size)
		local key = string.format('%.2f/%.2f', ratio, ratio_min)
		if key ~= self.layout_key then
			self.layout_key = key
			Elements:maybe('controls', 'reflow')
		end
	end))
end

---@param value string
---@return number|nil
local function parse_target_time(value)
	if value:match('^%d+$') then return tonumber(value) end

	local parts = {}
	for part in value:gmatch('[^:]+') do
		if not part:match('^%d+$') then return nil end
		parts[#parts + 1] = tonumber(part)
	end
	if #parts == 2 then
		if parts[2] >= 60 then return nil end
		return parts[1] * 60 + parts[2]
	elseif #parts == 3 then
		if parts[2] >= 60 or parts[3] >= 60 then return nil end
		return parts[1] * 3600 + parts[2] * 60 + parts[3]
	end
end

function Time:begin_edit()
	if self.editing or self.danmaku or not self:can_seek() then return end
	self.editing = true
	self.input = format_time(state.time, state.duration)
	self.cursor_index = #self.input
	self.select_all = true
	self.restore_edit_ime = state.ime_active == false
	if self.restore_edit_ime then mp.set_property_bool('input-ime', true) end

	local flags = {repeatable = true, complex = true}
	local function bind(key, handler)
		self:add_key_binding(key, {self:create_action(handler), flags}, 'time_input')
	end

	bind('any_unicode', function(info) self:handle_text_input(info) end)
	for index = 0, 9 do bind('kp' .. index, function(info) self:handle_text_input(info) end) end
	bind('bs', function(info) self:handle_backspace(info) end)
	bind('del', function(info) self:handle_delete(info) end)
	bind('left', function(info) self:handle_cursor_move(-1, info) end)
	bind('right', function(info) self:handle_cursor_move(1, info) end)
	bind('home', function(info) self:handle_cursor_home_end(false, info) end)
	bind('end', function(info) self:handle_cursor_home_end(true, info) end)
	bind('enter', function(info) self:handle_submit(info) end)
	bind('kp_enter', function(info) self:handle_submit(info) end)
	bind('esc', function(info) if info.event ~= 'up' then self:end_edit() end end)
	bind('ctrl+v', function(info) self:handle_paste(info) end)

	self.cancel_click_listener = cursor:once('primary_down', self:create_action(function()
		self:end_edit()
	end))
	request_render()
end

function Time:end_edit()
	if self.cancel_click_listener then
		self.cancel_click_listener()
		self.cancel_click_listener = nil
	end
	if not self.editing then return end
	if self.restore_edit_ime then mp.set_property_bool('input-ime', false) end
	self.restore_edit_ime = false
	self.editing = false
	self.input = ''
	self.cursor_index = 0
	self.select_all = false
	self:remove_key_bindings('time_input')
	request_render()
end

function Time:prepare_insert()
	if self.select_all then
		self.input, self.cursor_index, self.select_all = '', 0, false
	end
end

function Time:insert_text(value)
	if not value:match('^[0-9:]+$') then return end
	self:prepare_insert()
	if #self.input + #value > 16 then return end
	self.input = self.input:sub(1, self.cursor_index) .. value .. self.input:sub(self.cursor_index + 1)
	self.cursor_index = self.cursor_index + #value
	request_render()
end

function Time:handle_text_input(info)
	if info.event == 'up' then return end
	local text = info.key_text
	if not text and info.key_name then text = info.key_name:match('KP_?(%d)') end
	if text then self:insert_text(text) end
end

function Time:handle_backspace(info)
	if info.event == 'up' then return end
	if self.select_all then
		self.input, self.cursor_index, self.select_all = '', 0, false
	elseif self.cursor_index > 0 then
		self.input = self.input:sub(1, self.cursor_index - 1) .. self.input:sub(self.cursor_index + 1)
		self.cursor_index = self.cursor_index - 1
	end
	request_render()
end

function Time:handle_delete(info)
	if info.event == 'up' then return end
	if self.select_all then
		self.input, self.cursor_index, self.select_all = '', 0, false
	else
		self.input = self.input:sub(1, self.cursor_index) .. self.input:sub(self.cursor_index + 2)
	end
	request_render()
end

function Time:handle_cursor_move(amount, info)
	if info.event == 'up' then return end
	if self.select_all then self.select_all = false end
	self.cursor_index = clamp(0, self.cursor_index + amount, #self.input)
	request_render()
end

function Time:handle_cursor_home_end(to_end, info)
	if info.event == 'up' then return end
	self.select_all = false
	self.cursor_index = to_end and #self.input or 0
	request_render()
end

function Time:handle_paste(info)
	if info.event == 'up' then return end
	local value = get_clipboard()
	if value then self:insert_text(value:gsub('%s+', '')) end
end

function Time:handle_submit(info)
	if info.event == 'up' then return end
	local target = parse_target_time(self.input)
	if not target then
		mp.osd_message('请输入 90、01:30 或 1:02:03', 2)
		return
	end
	if not self:can_seek() then
		self:end_edit()
		return
	end
	if target > state.duration then
		mp.osd_message('输入时间超出视频时长', 2)
		return
	end
	mp.commandv('seek', target, 'absolute+exact')
	self:end_edit()
end

function Time:get_live_danmaku_source()
	local source = mp.get_property(LIVE_SEND_SOURCE) or ''
	return source ~= '' and source or nil
end

function Time:clear_danmaku_draft()
	self.danmaku_draft = ''
	self.danmaku_draft_source = nil
end

function Time:store_danmaku_draft()
	local source = self:get_live_danmaku_source()
	if source and self.danmaku_input:match('%S') then
		self.danmaku_draft = self.danmaku_input
		self.danmaku_draft_source = source
	else
		self:clear_danmaku_draft()
	end
end

function Time:clear_danmaku_pointer_capture(keep_up_listener)
	if self.danmaku_pointer_down_listener then
		self.danmaku_pointer_down_listener()
		self.danmaku_pointer_down_listener = nil
	end
	if keep_up_listener then return end
	if self.danmaku_pointer_up_listener then
		self.danmaku_pointer_up_listener()
		self.danmaku_pointer_up_listener = nil
	end
	if self.danmaku_pointer_capture_timeout then
		self.danmaku_pointer_capture_timeout:kill()
		self.danmaku_pointer_capture_timeout = nil
	end
	self.danmaku_pointer_capture_pending = false
end

function Time:install_danmaku_pointer_capture()
	self:clear_danmaku_pointer_capture()
	self.danmaku_pointer_down_listener = cursor:on_pre('primary_down', function()
		if self.destroyed or not self.danmaku or self.danmaku_sending then return false end
		if cursor.x >= self.ax and cursor.x <= self.bx and cursor.y >= self.ay and cursor.y <= self.by then
			return false
		end
		self.danmaku_pointer_capture_pending = true
		self:end_danmaku({preserve_draft = true, keep_pointer_capture = true})
		self.danmaku_pointer_capture_timeout = mp.add_timeout(0.5, function()
			self:clear_danmaku_pointer_capture()
		end)
		return true
	end)
	self.danmaku_pointer_up_listener = cursor:on_pre('primary_up', function()
		if not self.danmaku_pointer_capture_pending then return false end
		self:clear_danmaku_pointer_capture()
		return true
	end)
end

function Time:toggle_danmaku()
	if self.danmaku then
		if not self.danmaku_sending and not self.danmaku_input:match('%S') then
			self:end_danmaku({preserve_draft = true})
		end
		return
	end
	self:begin_danmaku()
end

function Time:begin_danmaku()
	if self.danmaku or not mp.get_property_bool(LIVE_SEND_AVAILABLE, false) then return end
	self:end_edit()
	self.danmaku = true
	local source = self:get_live_danmaku_source()
	if source and self.danmaku_draft_source == source then
		self.danmaku_input = self.danmaku_draft
	else
		self:clear_danmaku_draft()
		self.danmaku_input = ''
	end
	self.danmaku_cursor_index = #self.danmaku_input
	self.danmaku_sending = false
	self.danmaku_error = nil
	self.danmaku_active_request_id = nil
	self.restore_danmaku_ime = state.ime_active == false
	if self.restore_danmaku_ime then mp.set_property_bool('input-ime', true) end

	local flags = {repeatable = true, complex = true}
	local function bind(key, handler)
		self:add_key_binding(key, {self:create_action(handler), flags}, 'danmaku_input')
	end
	bind('any_unicode', function(info) self:handle_danmaku_text_input(info) end)
	bind('bs', function(info) self:handle_danmaku_backspace(info) end)
	bind('del', function(info) self:handle_danmaku_delete(info) end)
	bind('left', function(info) self:handle_danmaku_cursor_move(-1, info) end)
	bind('right', function(info) self:handle_danmaku_cursor_move(1, info) end)
	bind('home', function(info) self:handle_danmaku_cursor_home_end(false, info) end)
	bind('end', function(info) self:handle_danmaku_cursor_home_end(true, info) end)
	bind('enter', function(info) self:submit_danmaku(info) end)
	bind('kp_enter', function(info) self:submit_danmaku(info) end)
	bind('esc', function(info) if info.event ~= 'up' then self:end_danmaku({preserve_draft = true}) end end)
	bind('b', function(info)
		if info.event == 'up' then return end
		if not self.danmaku_input:match('%S') then
			self:end_danmaku({preserve_draft = true})
		else
			self:insert_danmaku_text('b')
		end
	end)
	bind('ctrl+v', function(info) self:handle_danmaku_paste(info) end)

	self:install_danmaku_pointer_capture()
	self.layout_key = nil
	self:queue_layout_refresh()
	request_render()
end

function Time:end_danmaku(opts)
	opts = opts or {}
	if not self.danmaku then return end
	if opts.preserve_draft then self:store_danmaku_draft() else self:clear_danmaku_draft() end
	self:clear_danmaku_pointer_capture(opts.keep_pointer_capture)
	if self.restore_danmaku_ime then mp.set_property_bool('input-ime', false) end
	self.restore_danmaku_ime = false
	self.danmaku = false
	self.danmaku_input = ''
	self.danmaku_cursor_index = 0
	self.danmaku_sending = false
	self.danmaku_error = nil
	self.danmaku_active_request_id = nil
	self:remove_key_bindings('danmaku_input')
	self.layout_key = nil
	self:queue_layout_refresh()
	request_render()
end

function Time:insert_danmaku_text(value)
	if self.danmaku_sending then return end
	value = tostring(value or ''):gsub('[\r\n]+', ' ')
	if value == '' then return end
	local head = self.danmaku_input:sub(1, self.danmaku_cursor_index)
	local tail = self.danmaku_input:sub(self.danmaku_cursor_index + 1)
	self.danmaku_input = head .. value .. tail
	self.danmaku_cursor_index = self.danmaku_cursor_index + #value
	self.danmaku_error = nil
	request_render()
end

function Time:handle_danmaku_text_input(info)
	if info.event ~= 'up' and info.key_text then self:insert_danmaku_text(info.key_text) end
end

function Time:handle_danmaku_backspace(info)
	if info.event == 'up' or self.danmaku_sending then return end
	local cursor = self.danmaku_cursor_index
	if cursor > 0 then
		local previous = utf8_prev(self.danmaku_input, cursor)
		self.danmaku_input = self.danmaku_input:sub(1, previous) .. self.danmaku_input:sub(cursor + 1)
		self.danmaku_cursor_index = previous
		self.danmaku_error = nil
		request_render()
	end
end

function Time:handle_danmaku_delete(info)
	if info.event == 'up' or self.danmaku_sending then return end
	local cursor = self.danmaku_cursor_index
	if cursor < #self.danmaku_input then
		local next_cursor = utf8_next(self.danmaku_input, cursor)
		self.danmaku_input = self.danmaku_input:sub(1, cursor) .. self.danmaku_input:sub(next_cursor + 1)
		self.danmaku_error = nil
		request_render()
	end
end

function Time:handle_danmaku_cursor_move(amount, info)
	if info.event == 'up' then return end
	local move = amount < 0 and utf8_prev or utf8_next
	local cursor = self.danmaku_cursor_index
	for _ = 1, math.abs(amount) do
		local next_cursor = move(self.danmaku_input, cursor)
		if next_cursor == cursor then break end
		cursor = next_cursor
	end
	self.danmaku_cursor_index = cursor
	request_render()
end

function Time:handle_danmaku_cursor_home_end(to_end, info)
	if info.event == 'up' then return end
	self.danmaku_cursor_index = to_end and #self.danmaku_input or 0
	request_render()
end

function Time:handle_danmaku_paste(info)
	if info.event == 'up' then return end
	local value = get_clipboard()
	if value then self:insert_danmaku_text(value) end
end

function Time:submit_danmaku(info)
	if info and info.event == 'up' then return end
	if not self.danmaku or self.danmaku_sending then return end
	if not self.danmaku_input:match('%S') then
		self.danmaku_error = '请输入弹幕'
		mp.osd_message(self.danmaku_error, 2)
		request_render()
		return
	end
	if not mp.get_property_bool(LIVE_SEND_AVAILABLE, false) then
		self.danmaku_error = '当前不是 Bilibili 直播间'
		mp.osd_message(self.danmaku_error, 2)
		request_render()
		return
	end

	self.danmaku_request_id = self.danmaku_request_id + 1
	self.danmaku_active_request_id = self.danmaku_request_id
	self.danmaku_sending = true
	self.danmaku_error = nil
	mp.commandv('script-message-to', 'bilibili_danmaku', 'send-live-danmaku', utils.format_json({
		id = self.danmaku_active_request_id,
		message = self.danmaku_input,
	}))
	request_render()
end

function Time:handle_danmaku_result(result)
	if not self.danmaku or result.id ~= self.danmaku_active_request_id then return end
	self.danmaku_sending = false
	if result.ok then
		mp.osd_message('弹幕已发送', 2)
		self:end_danmaku()
		return
	end
	self.danmaku_error = tostring(result.error or '弹幕发送失败')
	mp.osd_message(self.danmaku_error, 3)
	request_render()
end

function Time:render_danmaku(ass, visibility)
	local height = self.by - self.ay
	local gap = math.max(1, round(2 * state.scale))
	local padding = round(self.font_size * 0.45)
	local send_width = math.max(round(self.font_size * 2.9), round(60 * state.scale))
	local send_ax, send_bx = self.bx - send_width, self.bx
	local input_ax, input_bx = self.ax + gap, send_ax - gap
	local center_y = (self.ay + self.by) / 2
	local text = self.danmaku_input
	local input_color = self.danmaku_error and config.color.error or fg
	local input_border = self.danmaku_error and config.color.error or config.color.match

	cursor:zone('primary_down', {ax = input_ax, ay = self.ay, bx = input_bx, by = self.by}, function() end)
	cursor:zone('primary_down', {ax = send_ax, ay = self.ay, bx = send_bx, by = self.by},
		self:create_action(function() self:submit_danmaku() end))

	ass:rect(self.ax, self.ay, self.bx, self.by, {color = bg, opacity = visibility * 0.86, radius = state.radius})
	ass:rect(input_ax, self.ay, input_bx, self.by, {
		color = bg, opacity = visibility * 0.96, radius = state.radius,
		border = 1, border_color = input_border,
	})
	ass:rect(send_ax, self.ay, send_bx, self.by, {
		color = config.color.heatmap, opacity = visibility * (self.danmaku_sending and 0.55 or 1), radius = state.radius,
	})

	local text_opts = {
		size = self.font_size, color = bgt, border = options.text_border * state.scale, border_color = bg,
		clip = string.format('\\clip(%d,%d,%d,%d)', input_ax + padding, self.ay, input_bx - padding, self.by),
	}
	local caret_x
	if text == '' then
		text_opts.opacity = visibility * 0.48
		ass:txt(input_ax + padding, center_y, 4, '输入弹幕', text_opts)
		caret_x = input_ax + padding
	else
		text_opts.opacity = visibility
		ass:txt(input_ax + padding, center_y, 4, ass_escape(text), text_opts)
		caret_x = clamp(input_ax + padding, input_ax + padding + text_width(text:sub(1, self.danmaku_cursor_index), text_opts), input_bx - padding)
	end
	-- Show focus even while the IME is composing text which has not yet been
	-- committed through `any_unicode`.
	ass:rect(caret_x, center_y - self.font_size * 0.58, caret_x + math.max(1, state.scale),
		center_y + self.font_size * 0.58, {color = input_color, opacity = visibility})
	ass:txt((send_ax + send_bx) / 2, center_y, 5, self.danmaku_sending and '发送中' or '发送', {
		size = round(self.font_size * 0.82), color = fg, border = 0, opacity = visibility,
	})
end

function Time:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end

	if self.danmaku then
		local ass = assdraw.ass_new()
		self:render_danmaku(ass, visibility)
		return ass
	end

	if self.editing then
		cursor:zone('primary_click', self, function() end)
	elseif self:can_seek() then
		cursor:zone('primary_click', self, function() self:begin_edit() end)
	end

	local ass = assdraw.ass_new()
	local center_x, center_y = (self.ax + self.bx) / 2, (self.ay + self.by) / 2
	local text = self.editing and self.input or self:get_display_text()
	local opts = {size = self.font_size, color = bgt, border = options.text_border * state.scale, border_color = bg}

	if self.editing then
		local text_width_value = math.max(text_width(text == '' and '00:00' or text, opts), self.font_size * 3)
		local padding = round(self.font_size * 0.5)
		local ax, bx = center_x - text_width_value / 2 - padding, center_x + text_width_value / 2 + padding
		ass:rect(ax, self.ay, bx, self.by, {color = bg, opacity = 0.86, radius = state.radius, border = 1, border_color = fg})

		if self.select_all and text ~= '' then
			ass:rect(center_x - text_width_value / 2, center_y - self.font_size * 0.55,
				center_x + text_width_value / 2, center_y + self.font_size * 0.55, {color = fg, opacity = 0.8})
			opts.color, opts.border_color = bg, fg
		end

		ass:txt(center_x, center_y, 5, text == '' and '00:00' or ass_escape(text), opts)
		if not self.select_all then
			local text_left = center_x - text_width_value / 2
			local caret_x = text_left + text_width(text:sub(1, self.cursor_index), opts)
			ass:rect(caret_x, center_y - self.font_size * 0.58, caret_x + math.max(1, state.scale),
				center_y + self.font_size * 0.58, {color = fg, opacity = 1})
		end
	else
		local padding_x = round(self.font_size * 0.45)
		local padding_y = round(self.font_size * 0.12)
		local text_width_value = text_width(text, opts)
		local box_height = math.min(self.by - self.ay - state.scale * 4, self.font_size + padding_y * 2)
		local ax = center_x - text_width_value / 2 - padding_x
		local bx = center_x + text_width_value / 2 + padding_x
		local ay, by = center_y - box_height / 2, center_y + box_height / 2
		ass:rect(ax, ay, bx, by, {color = bg, opacity = visibility * 0.55, radius = state.radius})
		ass:txt(center_x, center_y, 5, text, opts)
	end

	return ass
end

return Time
