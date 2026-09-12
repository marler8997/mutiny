pub const Status = enum {
    not_attached,
    attached,
    unresponsive,
};

pub fn status(pid: u32) Status {
    return switch (mutinyipc.checkLiveness(pid)) {
        .no_window => .not_attached,
        .serving => .attached,
        .unresponsive => .unresponsive,
    };
}

pub const Game = struct {
    pid: u32,
    hwnd: win32.HWND,
};

/// Whether a top-level window is a Unity game's main window: the same test the DLL's attach
/// makes to find the main thread, and the one the GUI's shell hook makes for every new window.
pub fn isUnityWindow(hwnd: win32.HWND) bool {
    var class_name: [64:0]u16 = undefined;
    const len = win32.GetClassNameW(hwnd, &class_name, class_name.len);
    if (len == 0) return false;
    return std.mem.eql(u16, class_name[0..@intCast(len)], mutinyipc.unity_window_class);
}

const EnumContext = struct {
    allocator: std.mem.Allocator,
    games: std.ArrayListUnmanaged(Game) = .empty,
    err: ?error{OutOfMemory} = null,
};

fn enumWindowsProc(hwnd: win32.HWND, lparam: win32.LPARAM) callconv(.winapi) win32.BOOL {
    const context: *EnumContext = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (!isUnityWindow(hwnd)) return 1;
    var pid: u32 = undefined;
    if (0 == win32.GetWindowThreadProcessId(hwnd, &pid)) return 1;
    for (context.games.items) |game| if (game.pid == pid) return 1;
    context.games.append(context.allocator, .{ .pid = pid, .hwnd = hwnd }) catch |e| {
        context.err = e;
        return 0;
    };
    return 1;
}

/// Every running Unity game, one entry per process, found by its main window.
pub fn unityGames(allocator: std.mem.Allocator) error{ OutOfMemory, Reported }![]Game {
    var context: EnumContext = .{ .allocator = allocator };
    errdefer context.games.deinit(allocator);
    if (0 == win32.EnumWindows(enumWindowsProc, @bitCast(@intFromPtr(&context)))) {
        if (context.err) |e| return e;
        std.log.err("EnumWindows failed, error={f}", .{win32.GetLastError()});
        return error.Reported;
    }
    return context.games.toOwnedSlice(allocator);
}

pub const max_exe_path = 32767;

/// The process's exe path, as Windows knows it. Null with a log line if the process cannot
/// be opened, which for a game window's own process means it is elevated and we are not.
pub fn exePath(pid: u32, buf: *[max_exe_path:0]u16) ?[]const u16 {
    const process = win32.OpenProcess(.{ .QUERY_LIMITED_INFORMATION = 1 }, 0, pid) orelse {
        std.log.err("OpenProcess pid {} failed, error={f}", .{ pid, win32.GetLastError() });
        return null;
    };
    defer win32.closeHandle(process);
    var len: u32 = buf.len;
    if (0 == win32.QueryFullProcessImageNameW(process, .WIN32, buf, &len)) {
        std.log.err("QueryFullProcessImageName pid {} failed, error={f}", .{ pid, win32.GetLastError() });
        return null;
    }
    return buf[0..len];
}

const std = @import("std");
const win32 = @import("win32").everything;

const mutinyipc = @import("mutinyipc.zig");
