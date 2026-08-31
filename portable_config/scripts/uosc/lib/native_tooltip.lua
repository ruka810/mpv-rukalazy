local utils = require('mp.utils')

local NativeTooltip = {}
NativeTooltip.__index = NativeTooltip

local base64_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64_encode(value)
	return ((value:gsub('.', function(char)
		local byte, bits = char:byte(), ''
		for bit = 8, 1, -1 do
			bits = bits .. (byte % 2 ^ bit - byte % 2 ^ (bit - 1) > 0 and '1' or '0')
		end
		return bits
	end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(bits)
		if #bits < 6 then return '' end
		local encoded = 0
		for index = 1, 6 do
			if bits:sub(index, index) == '1' then encoded = encoded + 2 ^ (6 - index) end
		end
		return base64_chars:sub(encoded + 1, encoded + 1)
	end) .. ({'', '==', '='})[#value % 3 + 1])
end

local function create_pipe_writer(pipe_name)
	local loaded, ffi = pcall(require, 'ffi')
	if not loaded then return nil end

	local declared = pcall(ffi.cdef, [[
		typedef void* HANDLE;
		typedef unsigned long DWORD;
		typedef int BOOL;
		HANDLE __stdcall CreateFileW(const wchar_t* fileName, DWORD desiredAccess, DWORD shareMode,
			void* securityAttributes, DWORD creationDisposition, DWORD flagsAndAttributes, HANDLE templateFile);
		BOOL __stdcall WriteFile(HANDLE file, const void* buffer, DWORD bytesToWrite, DWORD* bytesWritten, void* overlapped);
		BOOL __stdcall CloseHandle(HANDLE object);
	]])
	if not declared then return nil end

	local kernel32 = ffi.load('kernel32')
	local generic_write, file_share_read, file_share_write, open_existing = 0x40000000, 0x1, 0x2, 3
	local invalid_handle = ffi.cast('HANDLE', -1)

	local function wide_ascii(value)
		local wide = ffi.new('wchar_t[?]', #value + 1)
		for index = 1, #value do wide[index - 1] = value:byte(index) end
		return wide
	end

	local path = wide_ascii('\\\\.\\pipe\\' .. pipe_name)
	return function(payload)
		local handle = kernel32.CreateFileW(path, generic_write, file_share_read + file_share_write, nil, open_existing, 0, nil)
		if handle == nil or handle == ffi.NULL or handle == invalid_handle then return false end

		local data = payload .. '\n'
		local written = ffi.new('DWORD[1]')
		local success = kernel32.WriteFile(handle, data, #data, written, nil)
		kernel32.CloseHandle(handle)
		return success ~= 0 and tonumber(written[0]) == #data
	end
end

function NativeTooltip:new()
	local platform = mp.get_property_native('platform')
	local script = mp.command_native({'expand-path', '~~/tools/uosc_native_tooltip.ps1'})
	local pid = mp.get_property_native('pid')
	local pipe_name = 'uosc-native-tooltip-' .. tostring(pid or mp.get_time())
	local writer = platform == 'windows' and create_pipe_writer(pipe_name) or nil
	local instance = setmetatable({
		available = type(script) == 'string' and script ~= '' and writer ~= nil,
		script = script,
		owner_pid = pid,
		pipe_name = pipe_name,
		write_pipe = writer,
		started = false,
		last_payload = nil,
		pending_payload = nil,
		retry_timer = nil,
	}, NativeTooltip)

	if instance.available then
		mp.register_event('shutdown', function() instance:shutdown() end)
		mp.observe_property('window-minimized', 'bool', function(_, minimized)
			if minimized then instance:hide() end
		end)
		-- Start the one persistent helper before the user first hovers a menu item.
		mp.add_timeout(0.1, function() instance:ensure_started() end)
	end

	return instance
end

function NativeTooltip:run_server()
	local args = {
		'powershell', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
		'-ExecutionPolicy', 'Bypass', '-File', self.script,
		'-Mode', 'launch', '-PipeName', self.pipe_name, '-OwnerPid', tostring(self.owner_pid or 0),
	}
	mp.command_native_async({name = 'subprocess', args = args, playback_only = false}, function() end)
end

function NativeTooltip:ensure_started()
	if self.started or not self.available then return end
	self.started = true
	self:run_server()
end

function NativeTooltip:send(payload)
	return self.write_pipe and self.write_pipe(payload) or false
end

function NativeTooltip:retry_pending()
	self.retry_timer = nil
	if not self.pending_payload then return end
	if self:send(self.pending_payload) then
		self.last_payload = self.pending_payload
		self.pending_payload = nil
		return
	end
	self.retry_timer = mp.add_timeout(0.05, function() self:retry_pending() end)
end

function NativeTooltip:queue_retry(payload)
	self.pending_payload = payload
	if not self.retry_timer then
		self.retry_timer = mp.add_timeout(0.05, function() self:retry_pending() end)
	end
end

---@param data {text: string; left: number; right: number; top: number; height: number; osd_width: number; osd_height: number; font_size: number}
---@return boolean shown
function NativeTooltip:show(data)
	if not self.available then return false end
	local window_id = mp.get_property_native('window-id')
	if not window_id or window_id == 0 then return false end

	data.command = 'show'
	data.window_id = tostring(window_id)
	local payload = base64_encode(utils.format_json(data))
	if self.pending_payload then
		self:queue_retry(payload)
		return false
	end
	if self.last_payload == payload then return true end

	self:ensure_started()
	if self:send(payload) then
		self.pending_payload = nil
		self.last_payload = payload
		return true
	end

	self:queue_retry(payload)
	return false
end

function NativeTooltip:hide()
	self.pending_payload = nil
	if self.retry_timer then self.retry_timer:kill(); self.retry_timer = nil end
	if not self.last_payload then
		return
	end
	self.last_payload = nil
	self:send(base64_encode('{"command":"hide"}'))
end

function NativeTooltip:shutdown()
	if not self.started then return end
	self.pending_payload = nil
	if self.retry_timer then self.retry_timer:kill(); self.retry_timer = nil end
	self:send(base64_encode('{"command":"shutdown"}'))
	self.last_payload = nil
	self.started = false
end

return NativeTooltip:new()
