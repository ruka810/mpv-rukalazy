local Element = require('elements/Element')

-- 字幕色号按钮：右下角 palette 图标，鼠标悬停到按钮上展开面板。
-- 面板内含：实时色块 + 可编辑 hex 输入框（回车应用）、10 个预设色块（单击应用 / 双击保存）。
-- 应用色号时写入 mpv.conf 持久化；预设额外持久化到 sub_color_presets.json。

local ICON = 'palette'
local DEFAULT_PRESETS = {
	'#FFFFFF', '#000000', '#FF0000', '#00FF00', '#0000FF',
	'#FFFF00', '#FF00FF', '#00FFFF', '#FF8800', '#888888',
}
local PRESETS_NUM = 10
local GRID_COLS, GRID_ROWS = 5, 2

-- ── 颜色工具 ──
-- 统一成 #RRGGBB；支持 #RRGGBB / RRGGBB / &HBBGGRR(/&)，忽略空白；无效返回 nil。
local function normalize_hex(input)
	if not input then return nil end
	local s = tostring(input):gsub('%s+', ''):upper()
	if s:sub(1, 2) == '&H' then
		s = s:gsub('^&H', ''):gsub('&$', '')
		local bb, gg, rr = s:match('^(%x%x)(%x%x)(%x%x)$')
		return bb and ('#' .. rr .. gg .. bb) or nil
	end
	s = s:gsub('^#', '')
	local r, g, b = s:match('^(%x%x)(%x%x)(%x%x)$')
	return r and ('#' .. r .. g .. b) or nil
end

-- #RRGGBB -> BGR 六位（uosc ass:rect/ass:txt 的 \\1c&H 需要 BGR）
local function to_ass_color(hex)
	local r, g, b = hex:match('#(%x%x)(%x%x)(%x%x)')
	return r and (b .. g .. r) or 'FFFFFF'
end

-- ── 预设持久化 ──
local function presets_path(file)
	return mp.find_config_file(file)
		or mp.command_native({ 'expand-path', '~~/' .. file })
end

local function load_presets(filename, current)
	local path = presets_path(filename)
	if path then
		local f = io.open(path, 'r')
		if f then
			local ok, data = pcall(function() return utils.parse_json(f:read('*a')) end)
			f:close()
			if ok and type(data) == 'table' then
				local presets = {}
				for i = 1, PRESETS_NUM do
					local hex = normalize_hex(data[i])
					if not hex then
						hex = (i == 1 and normalize_hex(current)) or DEFAULT_PRESETS[i]
					end
					presets[i] = hex
				end
				return presets
			end
		end
	end
	local presets = {}
	presets[1] = normalize_hex(current) or '#FFFFFF'
	for i = 2, PRESETS_NUM do presets[i] = DEFAULT_PRESETS[i] end
	return presets
end

local function save_presets(filename, presets)
	local path = presets_path(filename)
	if not path then return end
	local f = io.open(path, 'w')
	if f then
		f:write(utils.format_json(presets))
		f:close()
	end
end

-- 按属性名把颜色持久化写入 mpv.conf（例如 'sub-color' / 'sub-outline-color'），确保下次打开仍然生效。
local function persist_sub_prop(prop, hex)
	local path = mp.find_config_file('mpv.conf')
	if not path then return end
	local file = io.open(path, 'r')
	if not file then return end
	local content = file:read('*a')
	file:close()
	local pat = prop:gsub('%-', '%%-')
	if content:find(pat) then
		content = content:gsub(pat .. '%s*=%s*[^\r\n]*', prop .. ' = "' .. hex .. '"', 1)
	else
		content = content .. '\n' .. prop .. ' = "' .. hex .. '"\n'
	end
	file = io.open(path, 'w')
	if file then
		file:write(content)
		file:close()
	end
end

---@class SubColorButton : Element
local SubColorButton = class(Element)

function SubColorButton:new(id, props) return Class.new(self, id, props) --[[@as SubColorButton]] end
function SubColorButton:init(id, props)
	self.foreground = props.foreground or fg
	self.background = props.background or bg

	-- mode = 'fill'（文字）| 'outline'（描边），切换下面各套状态与预设
	self.mode = 'fill'
	self.current_color = normalize_hex(mp.get_property('sub-color')) or '#FFFFFF'
	self.outline_color = normalize_hex(mp.get_property('sub-outline-color')) or '#000000'
	self.presets = load_presets('sub_color_presets.json', self.current_color)
	self.outline_presets = load_presets('sub_outline_color_presets.json', self.outline_color)

	self.text_input = self.current_color
	self.cursor_index = #self.current_color
	self.text_input_active = false
	self.text_input_ime = false
	self.p_bounds = nil
	self.hover_index = nil
	self.hover_tab = nil
	self.last_click_index = nil
	self.last_click_time = 0
	self:refresh_tooltip()

	Element.init(self, id, props)

	self:observe_mp_property('sub-color', function(_, value)
		local hex = normalize_hex(value)
		if not hex then return end
		self.current_color = hex
		self:refresh_tooltip()
		if self.mode == 'fill' and not self.text_input_active then
			self.text_input, self.cursor_index = hex, #hex
		end
		request_render()
	end)
	self:observe_mp_property('sub-outline-color', function(_, value)
		local hex = normalize_hex(value)
		if not hex then return end
		self.outline_color = hex
		self:refresh_tooltip()
		if self.mode == 'outline' and not self.text_input_active then
			self.text_input, self.cursor_index = hex, #hex
		end
		request_render()
	end)
end

-- 当前 mode 对应的属性名、预设集合、预设文件名与当前色。
function SubColorButton:color_state()
	if self.mode == 'outline' then
		return { prop = 'sub-outline-color', presets = self.outline_presets, current = self.outline_color, file = 'sub_outline_color_presets.json' }
	end
	return { prop = 'sub-color', presets = self.presets, current = self.current_color, file = 'sub_color_presets.json' }
end

function SubColorButton:set_preset(index, hex)
	if self.mode == 'outline' then self.outline_presets[index] = hex else self.presets[index] = hex end
end

function SubColorButton:refresh_tooltip()
	local label = self.mode == 'outline' and '字幕描边颜色' or '字幕文字颜色'
	local cur = self.mode == 'outline' and self.outline_color or self.current_color
	self.tooltip = label .. ' ' .. cur
end

function SubColorButton:switch_mode(mode)
	if self.mode == mode then return end
	self.mode = mode
	self:text_input_blur()
	local cur = (mode == 'outline') and self.outline_color or self.current_color
	self.text_input, self.cursor_index = cur, #cur
	self.hover_index, self.hover_tab = nil, nil
	self:refresh_tooltip()
	request_render()
end

function SubColorButton:destroy()
	self:remove_key_bindings('subcolor')
	Element.destroy(self)
end

-- 面板显隐规则：
--  - 鼠标在按钮上 → 展开；
--  - 面板已展开时鼠标在面板内或「按钮—面板」过渡带内 → 保持；
--  - 其余 → 收起并失焦输入框。
function SubColorButton:update_proximity()
	if cursor.hidden then
		self.proximity = 0
		self:text_input_blur()
		return
	end

	local in_button = cursor:collides_with(self)
	local keep = in_button
	if not keep and self.proximity > 0 and self.p_bounds then
		local p = self.p_bounds
		local in_panel = cursor:collides_with(p)
		-- 鼠标从按钮向上移入面板时会经过一小段空隙，若不在面板内视为收起，
		-- 这段空隙会阻止面板正常展开。故把「按钮—面板」之间的过渡带也纳入保持范围。
		local in_connector =
			cursor.y <= self.ay and cursor.y >= p.by and cursor.x >= p.ax and cursor.x <= self.bx
		keep = in_panel or in_connector
	end

	if keep then
		self.proximity = 1
	else
		self.proximity = 0
		self:text_input_blur()
	end
end

-- 面板几何布局（始终存在，仅 proximity>0 时渲染）。整体尺寸约为按钮大小的一小半。
function SubColorButton:get_panel_bounds()
	-- 面板整体放大 25%（相对按钮 base scale）
	local scale = state.scale * 1.25
	local pad = round(6 * scale)
	local margin = round(8 * scale)
	local gap = round(4 * scale)
	local tr_h = round(20 * scale)
	local tab_h = round(18 * scale)
	local cw = round(30 * scale)
	local sw = round(22 * scale)
	local sp = round(4 * scale)
	local grid_h = GRID_ROWS * sw + (GRID_ROWS - 1) * sp

	local width = margin * 2 + GRID_COLS * sw + (GRID_COLS - 1) * sp
	-- 布局自上而下：tab 标签行 → 色块+输入框行 → 预设网格
	local height = pad + tab_h + gap + tr_h + gap + grid_h + pad

	local bx = self.bx
	local ax = self.bx - width
	ax = math.max(ax, round(8 * scale))
	local by = self.ay - round(6 * scale)
	local ay = by - height

	local ix = ax + margin

	local tab_ay = ay + pad
	local tab_by = tab_ay + tab_h
	-- 两个标签：文字 / 描边（各占一半可点击区域）
	local tab_w = (width - margin * 2) / 2
	local tab_fill = { ax = ix, ay = tab_ay, bx = ix + tab_w, by = tab_by }
	local tab_outline = { ax = ix + tab_w, ay = tab_ay, bx = bx - margin, by = tab_by }

	local row_ay = tab_by + gap
	local row_by = row_ay + tr_h
	-- 实时色块在左，输入框在右
	local swatch = { ax = ix, ay = row_ay, bx = ix + cw, by = row_by }
	local input = { ax = ix + cw + gap, ay = row_ay, bx = bx - margin, by = row_by }

	local gy = row_by + gap
	local swatches = {}
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			local i = row * GRID_COLS + col + 1
			swatches[i] = {
				index = i,
				ax = ix + col * (sw + sp),
				ay = gy + row * (sw + sp),
				bx = ix + col * (sw + sp) + sw,
				by = gy + row * (sw + sp) + sw,
			}
		end
	end

	return {
		ax = ax, ay = ay, bx = bx, by = by,
		swatch = swatch, input = input, swatches = swatches,
		tab_fill = tab_fill, tab_outline = tab_outline,
	}
end

-- 悬停高亮检测
function SubColorButton:update_hover(p)
	self.hover_index = nil
	self.hover_tab = nil
	if cursor.hidden then return end
	if cursor:collides_with(p.tab_fill) then self.hover_tab = 'fill' end
	if cursor:collides_with(p.tab_outline) then self.hover_tab = 'outline' end
	for i = 1, PRESETS_NUM do
		local s = p.swatches[i]
		if cursor:collides_with(s) then self.hover_index = i; break end
	end
end

function SubColorButton:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then request_render() return end
	if self.proximity <= 0 then self:text_input_blur() end

	local show_panel = self.proximity > 0

	local is_hover = self.proximity > 0
	local bg_opacity = config.opacity.controls
	if is_hover and bg_opacity < 0.3 then bg_opacity = 0.3 end

	local ass = assdraw.ass_new()

	-- 按钮背景
	ass:rect(self.ax, self.ay, self.bx, self.by, {
		color = self.background, radius = state.radius, opacity = visibility * bg_opacity,
	})

	-- 当前色小角标（右下角，跟随当前模式的文字/描边颜色）
	local dot = round((self.by - self.ay) * 0.3)
	ass:rect(self.bx - dot, self.by - dot, self.bx, self.by, {
		color = to_ass_color(self:color_state().current), opacity = visibility,
		border = 1, border_color = self.foreground, radius = math.max(1, round(dot * 0.3)),
	})

	-- 图标
	local cx_icon, cy_icon = round(self.ax + (self.bx - self.ax) / 2), round(self.ay + (self.by - self.ay) / 2)
	ass:icon(cx_icon, cy_icon, round((self.by - self.ay) * 0.7), ICON, {
		color = self.foreground, border = options.text_border * state.scale,
		border_color = self.background, opacity = visibility,
	})

	if show_panel then
		local p = self:get_panel_bounds()
		self.p_bounds = p
		self:update_hover(p)
		self:render_panel(ass, visibility, p)
	end

	-- 点击按钮：聚焦到输入框（面板已因悬停在按钮上而展开）
	cursor:zone('primary_click', self, self:create_action(function() self:focus_text_input() end))

	return ass
end

function SubColorButton:render_panel(ass, visibility, p)
	local scale = state.scale * 1.25
	local font = round(13 * scale)
	local fgcol = self.foreground
	local bgcol = self.background

	-- 面板背景
	ass:rect(p.ax, p.ay, p.bx, p.by, {
		color = bgcol, opacity = visibility * 0.95,
		radius = state.radius, border = 1, border_color = fgcol,
	})

	local st = self:color_state()

	-- 顶部切换标签：文字 / 描边
	local tab_font = round(12 * scale)
	local tab_opts = { size = tab_font, color = fgcol, border = options.text_border * scale, border_color = bgcol, opacity = visibility }
	local function draw_tab(tab, label, active, hover)
		ass:rect(tab.ax, tab.ay, tab.bx, tab.by, {
			color = bgcol, opacity = visibility * (active and 0.9 or 0.35),
			radius = round(state.radius * 0.6),
			border = active and 1 or 0, border_color = fgcol,
		})
		ass:txt((tab.ax + tab.bx) / 2, (tab.ay + tab.by) / 2, 5, label, tab_opts)
	end
	draw_tab(p.tab_fill, '文字', self.mode == 'fill', self.hover_tab == 'fill')
	draw_tab(p.tab_outline, '描边', self.mode == 'outline', self.hover_tab == 'outline')

	-- 实时输入色块（随输入变化预览）
	local live = normalize_hex(self.text_input) or st.current
	ass:rect(p.swatch.ax, p.swatch.ay, p.swatch.bx, p.swatch.by, {
		color = to_ass_color(live), opacity = visibility * 0.9,
		radius = round(state.radius * 0.8), border = 1, border_color = fgcol,
	})

	-- hex 输入框（文本左对齐绘制，光标跟随文本）
	local input = p.input
	local text = self.text_input
	local shown = text == '' and '#RRGGBB' or text
	local opts = {
		size = font, color = fgcol,
		border = options.text_border * scale, border_color = bgcol,
		opacity = visibility,
	}
	local pad = round(font * 0.45)
	local icy = (input.ay + input.by) / 2
	local text_x = input.ax + pad
	local right_limit = input.bx - pad

	ass:rect(input.ax, input.ay, input.bx, input.by, {
		color = bgcol, opacity = visibility * 0.6, radius = round(state.radius * 0.8),
		border = self.text_input_active and 1 or 0, border_color = fgcol,
	})

	if text == '' then opts.opacity = visibility * 0.55 end
	ass:txt(text_x, icy, 4, ass_escape(shown), opts)

	-- 光标：聚焦即显示（即使为空文本，光标停在起始位置），左对齐
	if self.text_input_active then
		local caret_x = text_x + text_width(text:sub(1, self.cursor_index), opts)
		caret_x = clamp(text_x, caret_x, right_limit)
		ass:rect(caret_x, icy - font * 0.58, caret_x + math.max(1, scale), icy + font * 0.58, {
			color = fgcol, opacity = 1,
		})
	end

	-- 预设色块
	for i = 1, PRESETS_NUM do
		local s = p.swatches[i]
		local hex = st.presets[i]
		local is_hover = self.hover_index == i
		local is_current = tostring(normalize_hex(hex)) == st.current
		ass:rect(s.ax, s.ay, s.bx, s.by, {
			color = to_ass_color(hex), opacity = visibility * 0.95,
			radius = round(state.radius * 0.7),
			border = is_hover and 2 or 1,
			border_color = is_hover and bgcol or fgcol,
		})
		if is_current then
			local marker = round(4 * scale)
			ass:rect(s.bx - marker, s.by - marker, s.bx, s.by, {
				color = fgcol, opacity = visibility, radius = round(scale),
			})
		end
	end
	-- 悬浮色号标签：在所有色块绘制之后再画，置于最上层，避免被其它色块/面板遮挡
	if self.hover_index then
		local s = p.swatches[self.hover_index]
		local hex = st.presets[self.hover_index]
		local tip_font = round(11 * scale)
		local tip_opts = { size = tip_font, color = bgcol, border = options.text_border * scale, border_color = fgcol, opacity = visibility }
		local tw = round(text_width(hex, tip_opts) + 8 * scale)
		local th = round(15 * scale)
		local tip_bx = (s.ax + s.bx) / 2 + tw / 2
		local tip_ax = tip_bx - tw
		local tip_ay = s.by + round(3 * scale)
		local tip_by = tip_ay + th
		ass:rect(tip_ax, tip_ay, tip_bx, tip_by, {
			color = fgcol, opacity = visibility * 0.95, radius = round(state.radius * 0.6),
		})
		ass:txt((tip_ax + tip_bx) / 2, (tip_ay + tip_by) / 2, 5, hex, tip_opts)
	end

	-- 命中检测（仅面板显示时注册，随 render 每次重建）
	cursor:zone('primary_click', p.tab_fill, self:create_action(function() self:switch_mode('fill') end))
	cursor:zone('primary_click', p.tab_outline, self:create_action(function() self:switch_mode('outline') end))
	cursor:zone('primary_click', p.swatch, self:create_action(function() self:focus_text_input() end))
	cursor:zone('primary_click', input, self:create_action(function() self:focus_text_input() end))
	-- 未聚焦时右键直接粘贴（已聚焦时由 key binding 处理，二者互补不冲突）
	cursor:zone('secondary_click', input, self:create_action(function()
		if not self.text_input_active then self:paste_from_clipboard() end
	end))
	for i = 1, PRESETS_NUM do
		(function(idx)
			local hex = st.presets[idx]
			cursor:zone('primary_click', p.swatches[idx], self:create_action(function() self:handle_preset_click(idx) end))
			cursor:zone('secondary_click', p.swatches[idx], self:create_action(function() self:copy_hex_to_clipboard(hex) end))
		end)(i)
	end
end

-- ── 交互 ──
function SubColorButton:focus_text_input()
	self.text_input_active = true
	-- 聚焦后从空开始输入，便于直接键入色号
	self.text_input = ''
	self.cursor_index = 0
	-- any_unicode 需 IME 开启才能收到字符
	self.text_input_ime = state.ime_active == false
	if self.text_input_ime then mp.set_property_bool('input-ime', true) end
	self:register_input_bindings()
	request_render()
end

function SubColorButton:text_input_blur()
	if self.text_input_active then
		self.text_input_active = false
		if self.text_input_ime then mp.set_property_bool('input-ime', false) end
		self.text_input_ime = false
		self:remove_key_bindings('subcolor')
		request_render()
	end
end

function SubColorButton:register_input_bindings()
	if self:has_keybindings('subcolor') then return end
	local flags = { repeatable = true, complex = true }
	local function bind(key, handler)
		self:add_key_binding(key, { self:create_action(handler), flags }, 'subcolor')
	end
	bind('any_unicode', function(info) self:handle_text_input(info) end)
	for i = 0, 9 do bind('kp' .. i, function(info) self:handle_text_input(info) end) end
	bind('kp_dec', function(info) self:handle_text_input(info) end)
	bind('bs', function(info) self:handle_backspace(info) end)
	bind('del', function(info) self:handle_delete(info) end)
	bind('left', function(info) self:handle_cursor_move(-1, info) end)
	bind('right', function(info) self:handle_cursor_move(1, info) end)
	bind('home', function(info) self:handle_cursor_home_end(false, info) end)
	bind('end', function(info) self:handle_cursor_home_end(true, info) end)
	bind('enter', function(info) self:handle_submit(info) end)
	bind('kp_enter', function(info) self:handle_submit(info) end)
	bind('ctrl+v', function(info) self:handle_paste(info) end)
	-- 右键直接粘贴（与 ctrl+v 同构，最可靠）
	self:add_key_binding('MBTN_RIGHT', { self:create_action(function(info) if info and info.event ~= 'up' then self:paste_from_clipboard() end end) }, 'subcolor')
	bind('esc', function(info) if info.event ~= 'up' then self:text_input_blur() end end)
end

function SubColorButton:handle_text_input(info)
	if info.event == 'up' then return end
	local text = info.key_text
	if not text then
		if info.key_name then text = info.key_name:match('KP_?(.+)') end
		if text and text == 'DEC' then text = '.' end
	end
	if not text then return end
	local filtered = ''
	for i = 1, #text do
		local ch = text:sub(i, i):upper()
		if ch == '#' then
			if self.cursor_index == 0 then filtered = filtered .. ch end
		elseif ch:match('[0-9A-F]') then
			filtered = filtered .. ch
		end
	end
	if filtered ~= '' then self:insert_text(filtered) end
end

-- 读取剪贴板并解析出第一个 #RRGGBB 填入输入框（粘贴后聚焦输入框便于继续编辑）。
function SubColorButton:paste_from_clipboard()
	self:focus_text_input()
	-- 同步 subprocess 是 mpv 中最可靠的取 stdout 方式（异步 subprocess 在此环境不可用）。
	-- 强制 PowerShell 用 ASCII 输出，避免 UTF-16 零字节导致解析失败。
	local ok, res = pcall(mp.command_native, {
		name = 'subprocess',
		capture_stdout = true,
		playback_only = false,
		args = {
			'powershell', '-NoProfile', '-Command',
			'[Console]::OutputEncoding=[System.Text.Encoding]::ASCII; [Console]::Write((Get-Clipboard))',
		},
	})
	if not ok then
		mp.osd_message('剪贴板读取失败: ' .. tostring(res), 2)
		return
	end
	if res.status ~= 0 or not res.stdout then
		mp.osd_message('剪贴板读取失败', 2)
		return
	end
	-- 兜底清理可能残留的零字节、空白与 BOM，再解析色号
	local s = tostring(res.stdout)
		:gsub('%z', ''):gsub('%s+', '')
		:gsub('^\239\187\191', ''):upper() -- 移除 UTF-8 BOM
	local s2 = s:gsub('^#', ''):gsub('^&H', ''):gsub('&$', '')
	local r, g, b = s2:match('^(%x%x)(%x%x)(%x%x)')
	if r then
		self.text_input = '#' .. r .. g .. b
		self.cursor_index = #self.text_input
		request_render()
	end
end

-- Ctrl+V 粘贴：读取剪贴板并填入输入框。
function SubColorButton:handle_paste(info)
	if info.event == 'up' then return end
	self:paste_from_clipboard()
end

-- 把色号复制到系统剪贴板
function SubColorButton:copy_hex_to_clipboard(hex)
	local scrubbed = hex:gsub('^#', ''):upper()
	local ok = pcall(mp.command_native, {
		name = 'subprocess',
		playback_only = false,
		args = { 'powershell', '-NoProfile', '-Command', 'Set-Clipboard -InputObject "#' .. scrubbed .. '"' },
	})
	if not ok then
		mp.osd_message('复制失败', 1.2)
		return
	end
	mp.osd_message('已复制 #' .. scrubbed, 1)
end

function SubColorButton:insert_text(value)
	if #self.text_input + #value > 7 then return end
	self.text_input = self.text_input:sub(1, self.cursor_index) .. value .. self.text_input:sub(self.cursor_index + 1)
	self.cursor_index = self.cursor_index + #value
	request_render()
end

function SubColorButton:handle_backspace(info)
	if info.event == 'up' then return end
	if self.cursor_index > 0 then
		self.text_input = self.text_input:sub(1, self.cursor_index - 1) .. self.text_input:sub(self.cursor_index + 1)
		self.cursor_index = self.cursor_index - 1
	end
	request_render()
end

function SubColorButton:handle_delete(info)
	if info.event == 'up' then return end
	if self.cursor_index < #self.text_input then
		self.text_input = self.text_input:sub(1, self.cursor_index) .. self.text_input:sub(self.cursor_index + 2)
	end
	request_render()
end

function SubColorButton:handle_cursor_move(amount, info)
	if info.event == 'up' then return end
	self.cursor_index = clamp(0, self.cursor_index + amount, #self.text_input)
	request_render()
end

function SubColorButton:handle_cursor_home_end(to_end, info)
	if info.event == 'up' then return end
	self.cursor_index = to_end and #self.text_input or 0
	request_render()
end

function SubColorButton:handle_submit(info)
	if info.event == 'up' then return end
	local hex = normalize_hex(self.text_input)
	if hex then
		local st = self:color_state()
		mp.set_property(st.prop, hex)
		persist_sub_prop(st.prop, hex)
		self:text_input_blur()
	else
		mp.osd_message('无效颜色，未修改', 1.2)
	end
end

function SubColorButton:handle_preset_click(index)
	local st = self:color_state()
	local now = mp.get_time()
	if self.last_click_index == index and now - self.last_click_time < 0.35 then
		-- 双击：保存颜色到该槽。优先保存「当前输入框中的有效色号」，
		-- 否则保存当前应用到字幕的颜色；保存后同时应用到字幕并提示。
		local hex = normalize_hex(self.text_input) or st.current
		self:set_preset(index, hex)
		save_presets(st.file, st.presets)
		mp.set_property(st.prop, hex)
		persist_sub_prop(st.prop, hex)
		self.last_click_index = nil
		mp.osd_message(string.format('已保存 #%s 到预设 %d', hex:gsub('^#', ''), index), 1)
	else
		self.last_click_index = index
		self.last_click_time = now
		mp.set_property(st.prop, st.presets[index])
		persist_sub_prop(st.prop, st.presets[index])
	end
end

return SubColorButton