local FocusGuard = {available = false, generation = 0}

local ok, ffi = pcall(require, 'ffi')
if not ok then return FocusGuard end

local cdef_ok = pcall(ffi.cdef, [[
    typedef void* HWND;
    typedef int BOOL;
    typedef unsigned long DWORD;
    typedef long long LPARAM;
    typedef BOOL (__stdcall *WNDENUMPROC)(HWND, LPARAM);

    HWND __stdcall GetForegroundWindow(void);
    DWORD __stdcall GetCurrentProcessId(void);
    DWORD __stdcall GetWindowThreadProcessId(HWND hWnd, DWORD *lpdwProcessId);
    BOOL __stdcall EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam);
    BOOL __stdcall IsWindow(HWND hWnd);
    BOOL __stdcall IsWindowVisible(HWND hWnd);
    HWND __stdcall GetWindow(HWND hWnd, unsigned int uCmd);
    BOOL __stdcall BringWindowToTop(HWND hWnd);
    BOOL __stdcall SetForegroundWindow(HWND hWnd);
]])
if not cdef_ok then return FocusGuard end

local C = ffi.C
local GW_OWNER = 4

local function is_own_window(hwnd)
    if hwnd == nil or C.IsWindow(hwnd) == 0 then return false end
    local process_id = ffi.new('DWORD[1]')
    C.GetWindowThreadProcessId(hwnd, process_id)
    return tonumber(process_id[0]) == tonumber(C.GetCurrentProcessId())
end

local function find_main_window()
    local found = nil
    local callback = ffi.cast('WNDENUMPROC', function(hwnd)
        if is_own_window(hwnd) and C.IsWindowVisible(hwnd) ~= 0 and C.GetWindow(hwnd, GW_OWNER) == nil then
            found = hwnd
            return 0
        end
        return 1
    end)
    C.EnumWindows(callback, 0)
    callback:free()
    return found
end

FocusGuard.available = true

-- Menu opens should never alter foreground ownership. Windows may briefly move
-- focus while a native helper window is created, so check a short grace period
-- instead of relying on a single zero-delay callback.
function FocusGuard:preserve_after_menu_open()
    if not self.available or not is_own_window(C.GetForegroundWindow()) then return end

    self.generation = self.generation + 1
    local generation = self.generation
    local delays = {0, 0.04, 0.12, 0.28}

    local function check(index)
        if generation ~= self.generation then return end
        if not is_own_window(C.GetForegroundWindow()) then
            local hwnd = find_main_window()
            if hwnd then
                C.BringWindowToTop(hwnd)
                C.SetForegroundWindow(hwnd)
                msg.warn('Restored mpv foreground focus after opening a uosc menu')
            end
        end
        if index < #delays then
            mp.add_timeout(delays[index + 1], function() check(index + 1) end)
        end
    end

    mp.add_timeout(delays[1], function() check(1) end)
end

return FocusGuard
