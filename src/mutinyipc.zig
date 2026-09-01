pub const window_class_name = "MutinyWindow";
pub const wm_copydata_run_script: usize = 0x4d55544e;
pub const wm_copydata_result: win32.LRESULT = 0x3b7e15a2;

pub const wm_heartbeat = win32.WM_APP + 0;
pub const heartbeat_result: win32.LRESULT = 0x6c4d2e91;

pub const max_string_len = std.math.maxInt(u16);

pub const start_export_name = "MutinyStart";

/// The default thread stack is too small when injecting into .NET assemblies, so always ask
/// for a reasonable 2MB.
pub const thread_stack_size = 2 * 1024 * 1024;

pub const StringList = struct {
    data: []const u16,
    remaining: u16,

    pub fn init(blob: []const u16) error{Malformed}!StringList {
        if (blob.len == 0) return error.Malformed;
        return .{ .data = blob[1..], .remaining = blob[0] };
    }

    pub fn next(list: *StringList) error{Malformed}!?[]const u16 {
        if (list.remaining == 0) {
            if (list.data.len != 0) return error.Malformed;
            return null;
        }
        if (list.data.len == 0) return error.Malformed;
        const len = list.data[0];
        if (list.data.len < 1 + @as(usize, len)) return error.Malformed;
        const string = list.data[1 .. 1 + @as(usize, len)];
        list.data = list.data[1 + @as(usize, len) ..];
        list.remaining -= 1;
        return string;
    }
};

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

const heartbeat_timeout_ms = 1000;

pub const Liveness = enum {
    no_window,
    serving,
    unresponsive,
};

pub fn checkLiveness(pid: u32) Liveness {
    const hwnd = findWindow(pid) orelse return .no_window;
    var result: usize = undefined;
    const sent = win32.SendMessageTimeoutW(
        hwnd,
        wm_heartbeat,
        0,
        0,
        win32.SMTO_ABORTIFHUNG,
        heartbeat_timeout_ms,
        &result,
    );
    if (sent == 0) return .unresponsive;
    if (result != @as(usize, @bitCast(heartbeat_result))) return .unresponsive;
    return .serving;
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
