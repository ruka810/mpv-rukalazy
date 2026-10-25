"""Drive the real Windows SaveFileDialog for export integration checks."""
import ctypes
from ctypes import wintypes
import time

USER32 = ctypes.WinDLL("user32", use_last_error=True)
CALLBACK = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
USER32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
USER32.FindWindowW.restype = wintypes.HWND
USER32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
USER32.SendMessageW.restype = wintypes.LPARAM
USER32.GetDlgCtrlID.argtypes = [wintypes.HWND]
USER32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
USER32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
USER32.EnumChildWindows.argtypes = [wintypes.HWND, CALLBACK, wintypes.LPARAM]


def children(window):
    result = []
    @CALLBACK
    def visit(child, _):
        name, text = ctypes.create_unicode_buffer(256), ctypes.create_unicode_buffer(1024)
        USER32.GetClassNameW(child, name, len(name))
        USER32.GetWindowTextW(child, text, len(text))
        result.append((child, USER32.GetDlgCtrlID(child), name.value, text.value))
        return True
    USER32.EnumChildWindows(window, visit, 0)
    return result


def save_as(destination, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        window = USER32.FindWindowW("#32770", "Export video clip")
        if window:
            controls = children(window)
            # 1001 is the filename edit; 41477 is the address bar edit.
            edits = [handle for handle, control_id, name, _ in controls if name == "Edit" and control_id == 1001]
            buttons = [handle for handle, control_id, name, _ in controls if name == "Button" and control_id == 1]
            if edits and buttons:
                time.sleep(0.3)  # Let the dialog finish applying its initial filename.
                value = ctypes.create_unicode_buffer(str(destination))
                USER32.SendMessageW(edits[0], 0x000C, 0, ctypes.addressof(value))  # WM_SETTEXT
                time.sleep(0.2)
                USER32.SendMessageW(buttons[0], 0x00F5, 0, 0)  # BM_CLICK
                return
        time.sleep(0.1)
    raise TimeoutError("Cannot find the export SaveFileDialog filename control")
