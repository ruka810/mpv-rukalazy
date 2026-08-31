local Button = require('elements/Button')

-- 播放模式按钮：将 单曲循环 / 乱序 / 列表循环 三键整合为一键。
-- 点击依次切换：无 -> 单曲 -> 乱序 -> 列表 -> 无 ...
---@class PlayModeButton : Button
local PlayModeButton = class(Button)

---@param id string
---@param props {icons: table, tooltip?: string, anchor_id?: string, active?: boolean}
function PlayModeButton:new(id, props) return Class.new(self, id, props) --[[@as PlayModeButton]] end
function PlayModeButton:init(id, props)
	self.icons = props.icons
	self.states = {
		{icon = self.icons.none, name = '顺序播放'},
		{icon = self.icons.loop_file, name = '单曲循环'},
		{icon = self.icons.shuffle, name = '乱序播放'},
		{icon = self.icons.loop_playlist, name = '列表循环'},
	}
	self.current_state_index = 1
	Button.init(self, id, {
		icon = self.states[1].icon,
		active = false,
		tooltip = props.tooltip,
		anchor_id = props.anchor_id,
	})

	self.on_click = function()
		self:apply_state(self.states[self.current_state_index + 1] or self.states[1])
	end

	local function refresh() self:refresh_from_props() end
	self:observe_mp_property('loop-file', 'string', refresh)
	self:observe_mp_property('loop-playlist', 'string', refresh)
	self:observe_mp_property('shuffle', 'string', refresh)
	self:refresh_from_props()
end

---根据目标状态应用对应属性组合
---@param state {icon: string, name: string}
function PlayModeButton:apply_state(state)
	if self.states[2] == state then -- 单曲
		mp.set_property('loop-file', 'inf')
		mp.set_property('loop-playlist', 'no')
		mp.set_property('shuffle', 'no')
	elseif self.states[3] == state then -- 乱序
		mp.set_property('loop-file', 'no')
		mp.set_property('loop-playlist', 'no')
		mp.set_property('shuffle', 'yes')
	elseif self.states[4] == state then -- 列表
		mp.set_property('loop-file', 'no')
		mp.set_property('loop-playlist', 'inf')
		mp.set_property('shuffle', 'no')
	else -- 无
		mp.set_property('loop-file', 'no')
		mp.set_property('loop-playlist', 'no')
		mp.set_property('shuffle', 'no')
	end
end

---根据当前属性反推出所处模式并刷新按钮显示
function PlayModeButton:refresh_from_props()
	local loop_file = tostring(mp.get_property('loop-file') or 'no')
	local loop_playlist = tostring(mp.get_property('loop-playlist') or 'no')
	local shuffle = tostring(mp.get_property('shuffle') or 'no')

	local index = 1
	if shuffle == 'yes' then
		index = 3
	elseif loop_file == 'inf' then
		index = 2
	elseif loop_playlist == 'inf' then
		index = 4
	end

	self.current_state_index = index
	self.icon = self.states[index].icon
	-- 仅在非“无”模式下高亮
	self.active = index ~= 1
	self.tooltip = self.states[index].name
	request_render()
end

return PlayModeButton