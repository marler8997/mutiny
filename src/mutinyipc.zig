pub const window_class_name = "MutinyWindow";
pub const wm_copydata_run_script: usize = 0x4d55544e;
pub const wm_copydata_result: win32.LRESULT = 0x3b7e15a2;

pub const wm_heartbeat = win32.WM_APP + 0;
pub const heartbeat_result: win32.LRESULT = 0x6c4d2e91;

pub fn findWindow(pid: u32) ?win32.HWND {
    var prev: ?win32.HWND = null;
    while (true) {
        const hwnd = win32.FindWindowExW(
            win32.HWND_MESSAGE,
            prev,
            win32.L(window_class_name),
            null,
        ) orelse return null;
        var hwnd_pid: u32 = undefined;
        const tid = win32.GetWindowThreadProcessId(hwnd, &hwnd_pid);
        if (tid == 0) win32.panicWin32("GetWindowThreadProcessId", win32.GetLastError());
        if (hwnd_pid == pid) return hwnd;
        prev = hwnd;
    }
}

const win32 = @import("win32").everything;
