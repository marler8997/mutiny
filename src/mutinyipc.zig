pub const window_class_name = "MutinyWindow";
pub const wm_copydata_run_script: usize = 0x4d55544e;
pub const wm_copydata_result: win32.LRESULT = 0x3b7e15a2;

pub const wm_heartbeat = win32.WM_APP + 0;
pub const heartbeat_result: win32.LRESULT = 0x6c4d2e91;

pub const pipe_name_buf_len = 64;

pub fn formatClientPipeName(buf: *[pipe_name_buf_len]u16, client_pid: u32) [:0]u16 {
    var utf8: [pipe_name_buf_len]u8 = undefined;
    const name = std.fmt.bufPrint(
        &utf8,
        "\\\\.\\pipe\\mutiny-client-{}",
        .{client_pid},
    ) catch unreachable;
    const len = std.unicode.wtf8ToWtf16Le(buf, name) catch unreachable;
    buf[len] = 0;
    return buf[0..len :0];
}

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

const std = @import("std");
const win32 = @import("win32").everything;
