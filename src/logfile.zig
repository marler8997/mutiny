pub const global = struct {
    pub var write_log_mutex: Mutex = .{};

    const get_log = struct {
        var mutex: Mutex = .{};
        var cached: ?std.fs.File = null;
    };

    pub fn get() struct { std.fs.File, ?OpenLogError } {
        get_log.mutex.lock();
        defer get_log.mutex.unlock();
        if (get_log.cached) |file| return .{ file, null };
        get_log.cached, const err = openLog();
        return .{ get_log.cached.?, err };
    }

    const Name = union(enum) {
        success: []const u16,
        err: NameError,
    };
    const name = struct {
        var mutex: Mutex = .{};
        var cached: ?Name = null;
    };
    pub fn getName() Name {
        name.mutex.lock();
        defer name.mutex.unlock();
        if (name.cached == null) {
            name.cached = if (getname.fromExe(getImagePathName() orelse win32.L(""))) |string|
                .{ .success = string }
            else |err|
                .{ .err = .{ .get_name_error = err } };
        }
        return name.cached.?;
    }
};

pub const NameError = struct {
    get_name_error: getname.Error,
    pub fn format(err: *const NameError, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (builtin.os.tag == .windows) {
            const image_path_name = getImagePathName() orelse win32.L("");
            try writer.print(
                "failed to extract name from PEB image name '{f}' ({s})",
                .{
                    std.unicode.fmtUtf16Le(image_path_name),
                    @as([]const u8, switch (err.get_name_error) {
                        error.Empty => "its empty",
                        error.EndsInSeparator => "it ends with a file separator",
                        error.JustDotExe => "cant be just '.exe'",
                    }),
                },
            );
        }
    }
};

fn openLog() struct { std.fs.File, ?OpenLogError } {
    const localappdata = appdata.get() orelse return .{
        std.fs.File.stderr(),
        .missing_localappdata,
    };

    const game = switch (global.getName()) {
        .success => |s| s,
        .err => |err| return .{ std.fs.File.stderr(), .{ .name_error = err } },
    };

    var path_buf: [appdata.max_path]u16 = undefined;
    const log_path = switch (appdata.format(
        &path_buf,
        localappdata,
        &.{ win32.L("mutiny"), game, win32.L("log") },
    )) {
        .ok => |p| p,
        .too_long => return .{ std.fs.File.stderr(), .{ .path_too_long = .{
            .localappdata_len = localappdata.len,
            .name_len = game.len,
        } } },
    };

    var first_attempt = true;
    while (true) : (first_attempt = false) {
        const handle = win32.CreateFileW(
            log_path,
            .{ .FILE_APPEND_DATA = 1 }, // all writes append to end of file
            .{ .READ = 1 },
            null,
            .OPEN_ALWAYS,
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        );
        if (handle != win32.INVALID_HANDLE_VALUE) return .{ .{ .handle = handle }, null };
        const err = win32.GetLastError();
        if (!first_attempt) return .{ std.fs.File.stderr(), .{ .open_error = err } };
        switch (err) {
            // first run for this game: %LOCALAPPDATA%\mutiny\<Game> doesn't exist yet
            .ERROR_PATH_NOT_FOUND => {
                const parent_dir_len = appdata.parentDirLen(log_path);
                std.debug.assert(parent_dir_len > 0);
                if (appdata.makeDirs(&path_buf, parent_dir_len)) |e| return .{
                    std.fs.File.stderr(),
                    .{ .mkdir_error = e },
                };
            },
            else => return .{ std.fs.File.stderr(), .{ .open_error = err } },
        }
    }
}

const OpenFileError = if (builtin.os.tag == .windows) win32.WIN32_ERROR else std.fs.File.OpenError;
const MkdirError = if (builtin.os.tag == .windows) win32.WIN32_ERROR else std.fs.Dir.MakeError;

pub const OpenLogError = union(enum) {
    missing_localappdata,
    name_error: NameError,
    path_too_long: struct { localappdata_len: usize, name_len: usize },
    open_error: OpenFileError,
    mkdir_error: MkdirError,
    pub fn format(err: *const OpenLogError, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (err.*) {
            .missing_localappdata => try writer.print("no LOCALAPPDATA environment variable", .{}),
            .name_error => |e| try writer.print("{f}", .{&e}),
            .path_too_long => |e| try writer.print(
                "LOCALAPPDATA environment variable ({} chars) and or exe name ({} chars) is too long",
                .{ e.localappdata_len, e.name_len },
            ),
            .open_error => |e| try writer.print("open log file failed, error={f}", .{e}),
            .mkdir_error => |e| try writer.print("mkdir for log file, error={f}", .{e}),
        }
    }
};

pub fn writeLogPrefix(writer: *std.Io.Writer) error{WriteFailed}!void {
    // const name: []const u16 = blk: {
    //     const p = getImagePathName() orelse break :blk win32.L("?");
    //     break :blk getBasename(p);
    // };
    var time: win32.SYSTEMTIME = undefined;
    win32.GetSystemTime(&time);
    const name: []const u16 = switch (global.getName()) {
        .success => |s| s,
        .err => win32.L("?"),
    };
    try writer.print(
        "{:0>2}:{:0>2}:{:0>2}.{:0>3}|{}|{}|{f}|",
        .{
            time.wHour,
            time.wMinute,
            time.wSecond,
            time.wMilliseconds,
            win32.GetCurrentProcessId(),
            win32.GetCurrentThreadId(),
            std.unicode.fmtUtf16Le(name),
        },
    );
}

fn getImagePathName() ?[]const u16 {
    const str = &std.os.windows.peb().ProcessParameters.ImagePathName;
    if (str.Buffer) |buffer|
        return buffer[0..@divTrunc(str.Length, 2)];
    return null;
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const appdata = @import("appdata.zig");
const getname = @import("getname.zig");
const Mutex = @import("Mutex.zig");
