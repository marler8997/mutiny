const global = struct {
    var localappdata: union(enum) {
        unresolved,
        resolved: ?PathLen,
    } = .unresolved;
    // The value is copied out of the process environment block into this
    // buffer. The OS frees and reallocates that block whenever anyone calls
    // SetEnvironmentVariable (games and their launchers do), so a slice into
    // it goes stale; an earlier version cached exactly such a slice.
    var localappdata_buf: [max_path + 1]u16 = undefined;
};

pub fn get() ?[:0]const u16 {
    if (builtin.os.tag != .windows) @panic("todo");
    blk: switch (global.localappdata) {
        .unresolved => {
            @branchHint(.unlikely);
            global.localappdata = .{ .resolved = resolve() };
            continue :blk global.localappdata;
        },
        .resolved => |maybe_len| return if (maybe_len) |len|
            global.localappdata_buf[0..len :0]
        else
            null,
    }
}

fn resolve() ?PathLen {
    // GetEnvironmentVariableW copies out of the environment block while holding
    // the PEB lock, so it cannot race a concurrent SetEnvironmentVariable the
    // way walking the block by hand does.
    const len = win32.GetEnvironmentVariableW(
        win32.L("LOCALAPPDATA"),
        @ptrCast(&global.localappdata_buf),
        global.localappdata_buf.len,
    );
    if (len == 0) switch (win32.GetLastError()) {
        .ERROR_ENVVAR_NOT_FOUND => return null,
        else => |e| std.debug.panic(
            "GetEnvironmentVariable LOCALAPPDATA failed, error={}",
            .{@intFromEnum(e)},
        ),
    };
    if (len >= global.localappdata_buf.len) std.debug.panic(
        "LOCALAPPDATA is {} chars which exceeds the {} char limit",
        .{ len - 1, max_path },
    );
    std.debug.assert(global.localappdata_buf[len] == 0);
    return @intCast(len);
}

pub const max_path = 350;
pub const PathLen = std.math.IntFittingRange(0, max_path);

pub fn format(
    path_buf: *[max_path]u16,
    localappdata: []const u16,
    sub_paths: []const []const u16,
) union(enum) {
    ok: [:0]u16,
    too_long,
} {
    // A trailing separator on LOCALAPPDATA would double up when we join onto it.
    var prefix_len = localappdata.len;
    while (prefix_len > 0 and localappdata[prefix_len - 1] == '\\') : (prefix_len -= 1) {}

    if (prefix_len + 1 > path_buf.len) return .too_long;
    @memcpy(path_buf[0..prefix_len], localappdata[0..prefix_len]);
    var len = prefix_len;

    for (sub_paths) |sub_path| {
        // a separator before each component, and room for the NUL after it
        if (len + 1 + sub_path.len + 1 > path_buf.len) return .too_long;
        path_buf[len] = '\\';
        len += 1;
        @memcpy(path_buf[len..][0..sub_path.len], sub_path);
        len += sub_path.len;
    }

    path_buf[len] = 0;
    return .{ .ok = path_buf[0..len :0] };
}

pub fn makeDirs(path_buf: *[max_path]u16, len: usize) ?win32.WIN32_ERROR {
    std.debug.assert(len + 1 <= max_path);

    const first_error = createDirAt(path_buf, len) orelse return null;
    switch (first_error) {
        .ERROR_PATH_NOT_FOUND => {},
        else => |e| return e,
    }
    const parent_len = parentDirLen(path_buf[0..len]);
    if (parent_len == 0) return first_error;
    if (makeDirs(path_buf, parent_len)) |err| return err;

    return createDirAt(path_buf, len);
}

fn createDirAt(path_buf: *[max_path]u16, len: usize) ?win32.WIN32_ERROR {
    const displaced = path_buf[len];
    path_buf[len] = 0;
    defer path_buf[len] = displaced;
    if (0 != win32.CreateDirectoryW(path_buf[0..len :0], null)) return null;
    return switch (win32.GetLastError()) {
        .ERROR_ALREADY_EXISTS => null,
        else => |e| e,
    };
}

pub fn parentDirLen(path: []const u16) usize {
    var i = path.len;
    while (i > 0 and path[i - 1] == '\\') : (i -= 1) {}
    while (i > 0) : (i -= 1) {
        if (path[i - 1] != '\\') continue;
        var end = i - 1;
        while (end > 0 and path[end - 1] == '\\') : (end -= 1) {}
        return end;
    }
    return 0;
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
