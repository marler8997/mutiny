const global = struct {
    var localappdata: union(enum) {
        unresolved,
        resolved: ?[:0]const u16,
    } = .unresolved;
};

pub fn get() ?[:0]const u16 {
    switch (global.localappdata) {
        .unresolved => {
            @branchHint(.unlikely);
            global.localappdata = .{ .resolved = findEnv(win32.L("LOCALAPPDATA")) };
            return global.localappdata.resolved;
        },
        .resolved => |p| return p,
    }
}

pub const max_path = 350;

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

fn findEnv(name: []const u16) ?[:0]const u16 {
    var p: [*:0]const u16 = std.os.windows.peb().ProcessParameters.Environment;
    while (p[0] != 0) {
        const entry: [:0]const u16 = std.mem.span(p); // "NAME=VALUE", excludes the \0
        p += entry.len + 1; // step to the next entry
        // Separator is the first '=' at index >= 1. Starting at 1 keeps the
        // special drive/exit entries intact, e.g. "=C:=C:\\dir", "=ExitCode=0".
        const eq = std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse continue;
        if (eqlNameAsciiCI(entry[0..eq], name))
            return entry[eq + 1 ..]; // open-ended reslice keeps the sentinel
    }
    return null;
}
fn eqlNameAsciiCI(left: []const u16, right: []const u16) bool {
    if (left.len != right.len) return false;
    for (left, right) |l, r| {
        if (toUpper(l) != toUpper(r)) return false;
    }
    return true;
}
fn toUpper(c: u16) u16 {
    return if (c < 128) std.ascii.toUpper(@intCast(c)) else c;
}

const std = @import("std");
const win32 = @import("win32").everything;
