local path = 'E:/mpv-lazy/portable_config/scripts/uosc/elements/SubColorButton.lua'
local controls_path = 'E:/mpv-lazy/portable_config/scripts/uosc/elements/Controls.lua'
local main_path = 'E:/mpv-lazy/portable_config/scripts/uosc/main.lua'
local out = io.open('E:/mpv-lazy/__syntax_result.txt', 'w')
local function check(p)
	local f = io.open(p, 'rb')
	if not f then return p .. ' :: FILE NOT FOUND' end
	local c = f:read('*a'); f:close()
	local fn, err = load(c, p)
	return p .. ' :: ' .. (fn and 'OK' or ('ERR: ' .. tostring(err)))
end
out:write('SubColorButton => ' .. check(path) .. '\n')
out:write('Controls => ' .. check(controls_path) .. '\n')
out:write('main => ' .. check(main_path) .. '\n')
out:close()