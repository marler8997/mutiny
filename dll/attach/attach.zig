const global = struct {
    var active_thread_id: u32 = 0;
    var mutex: std.atomic.Value(?win32.HANDLE) = .init(null);
};

pub fn activeThreadId() u32 {
    return global.active_thread_id;
}

comptime {
    @export(&MutinyAttach, .{ .name = mutinyipc.attach_export_name });
}
fn MutinyAttach(context: ?*anyopaque) callconv(.winapi) u32 {
    const timeout: Timeout = .{ .start = win32.GetTickCount64(), .ms = @intCast(@intFromPtr(context)) };
    std.log.info("MutinyAttach (timeout {} ms)", .{timeout.ms});
    var maybe_module: ?win32.HINSTANCE = null;
    if (0 != win32.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(@intFromPtr(&MutinyAttach)),
        &maybe_module,
    )) {
        std.log.info("module \"Mutiny.dll\" at 0x{x}", .{@intFromPtr(maybe_module.?)});
    }

    const mutex = claimMutex(timeout.remaining()) orelse return mutinyipc.AttachResult.fail;
    defer if (0 == win32.ReleaseMutex(mutex)) win32.panicWin32("ReleaseMutex", win32.GetLastError());

    global.active_thread_id = win32.GetCurrentThreadId();
    defer global.active_thread_id = 0;

    writeExePath() catch return mutinyipc.AttachResult.fail;

    var state: dll_main.AttachState = .{};
    while (true) switch (state.update()) {
        .attached => {
            std.log.info("attached", .{});
            return mutinyipc.AttachResult.success;
        },
        .failed => return mutinyipc.AttachResult.fail,
        .retry_ms => |ms| {
            const remaining = timeout.remaining();
            if (remaining == 0) {
                std.log.err("attach timed out after {} ms in the {t} stage", .{ timeout.ms, state.stage });
                return mutinyipc.AttachResult.fail;
            }
            win32.Sleep(@min(ms, remaining));
        },
    };
}

fn writeExePath() error{Reported}!void {
    const image_path = logfile.getImagePathName() orelse {
        std.log.err("cannot write exepath: the PEB has no image path", .{});
        return error.Reported;
    };
    const name = switch (logfile.global.getName()) {
        .success => |s| s,
        .err => |err| {
            std.log.err("cannot write exepath: {f}", .{err});
            return error.Reported;
        },
    };
    const localappdata = appdata.get() orelse {
        std.log.err("cannot write exepath: no LOCALAPPDATA environment variable", .{});
        return error.Reported;
    };
    var path_buf: [appdata.max_path]u16 = undefined;
    const path = switch (appdata.format(
        &path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("exepath") },
    )) {
        .ok => |p| p,
        .too_long => {
            std.log.err(
                "exepath too long (LOCALAPPDATA is {} chars, exe name '{f}' is {} chars)",
                .{ localappdata.len, fmtW(name), name.len },
            );
            return error.Reported;
        },
    };
    if (appdata.makeDirs(&path_buf, appdata.parentDirLen(path))) |err| {
        std.log.err("create app directory for '{f}' failed, error={f}", .{ fmtW(path), err });
        return error.Reported;
    }

    var utf8_buf: [appdata.max_exepath]u8 = undefined;
    const utf8_len = std.unicode.calcWtf8Len(image_path);
    if (utf8_len > utf8_buf.len) {
        std.log.err("image path is {} bytes as UTF-8, too long to write (max {})", .{ utf8_len, appdata.max_exepath });
        return error.Reported;
    }
    std.debug.assert(utf8_len == std.unicode.wtf16LeToWtf8(&utf8_buf, image_path));

    const max_attempts = 10;
    const retry_sleep_ms = 10;
    var attempt: u32 = 1;
    while (attempt <= max_attempts) : (attempt += 1) {
        if (try exePathMatches(path, utf8_buf[0..utf8_len])) return;

        if (attempt > 1) {
            std.log.err("exe path still does not match after writing it", .{});
            win32.Sleep(retry_sleep_ms);
        }

        {
            const handle = win32.CreateFileW(
                path,
                .{ .FILE_WRITE_DATA = 1 },
                .{ .READ = 1 },
                null,
                .CREATE_ALWAYS,
                .{ .FILE_ATTRIBUTE_NORMAL = 1 },
                null,
            );
            if (handle == win32.INVALID_HANDLE_VALUE) {
                std.log.err("create '{f}' failed, error={f}", .{ fmtW(path), win32.GetLastError() });
                return error.Reported;
            }
            defer win32.closeHandle(handle);
            const file: std.fs.File = .{ .handle = handle };
            file.writeAll(utf8_buf[0..utf8_len]) catch |err| {
                std.log.err("write '{f}' failed with {t}", .{ fmtW(path), err });
                return error.Reported;
            };
            std.log.info("wrote '{f}' to '{f}'", .{ fmtW(image_path), fmtW(path) });
        }
    }

    std.log.err("failed to write '{f}' to '{f}' after {} attempts", .{ fmtW(image_path), fmtW(path), max_attempts });
    return error.Reported;
}

fn exePathMatches(path: [:0]const u16, expected: []const u8) error{Reported}!bool {
    const handle = win32.CreateFileW(
        path,
        .{ .FILE_READ_DATA = 1 },
        .{ .READ = 1, .WRITE = 1 },
        null,
        .OPEN_EXISTING,
        .{ .FILE_ATTRIBUTE_NORMAL = 1 },
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => return false,
        else => |e| {
            std.log.err("open '{f}' failed, error={f}", .{ fmtW(path), e });
            return error.Reported;
        },
    };
    defer win32.closeHandle(handle);
    const file: std.fs.File = .{ .handle = handle };
    var buf: [appdata.max_exepath + 1]u8 = undefined;
    const len = file.readAll(&buf) catch |err| {
        std.log.err("read '{f}' failed with {t}", .{ fmtW(path), err });
        return error.Reported;
    };
    return std.mem.eql(u8, buf[0..len], expected);
}

const Timeout = struct {
    start: u64,
    ms: u32,

    fn remaining(timeout: Timeout) u32 {
        const elapsed = win32.GetTickCount64() - timeout.start;
        return @intCast(timeout.ms -| @min(elapsed, std.math.maxInt(u32)));
    }
};

fn attachMutex() ?win32.HANDLE {
    if (global.mutex.load(.acquire)) |mutex| return mutex;
    const created = win32.CreateMutexW(null, 0, null) orelse {
        std.log.err("CreateMutex failed, error={f}", .{win32.GetLastError()});
        return null;
    };
    if (global.mutex.cmpxchgStrong(null, created, .acq_rel, .acquire)) |winner| {
        win32.closeHandle(created);
        return winner;
    }
    return created;
}

fn claimMutex(timeout_ms: u32) ?win32.HANDLE {
    const mutex = attachMutex() orelse return null;
    switch (win32.WaitForSingleObject(mutex, timeout_ms)) {
        @intFromEnum(win32.WAIT_OBJECT_0) => {},
        @intFromEnum(win32.WAIT_ABANDONED) => std.log.info("the previous attach thread died holding the mutex, taking over", .{}),
        @intFromEnum(win32.WAIT_TIMEOUT) => {
            std.log.err("another attach is still in progress after {} ms", .{timeout_ms});
            return null;
        },
        @intFromEnum(win32.WAIT_FAILED) => {
            std.log.err("wait on the attach mutex failed, error={f}", .{win32.GetLastError()});
            return null;
        },
        else => |result| std.debug.panic("WaitForSingleObject returned {d}", .{result}),
    }
    return mutex;
}

const fmtW = std.unicode.fmtUtf16Le;

const std = @import("std");
const win32 = @import("win32").everything;
const dll_main = @import("dll_main");

const appdata = dll_main.appdata;
const logfile = dll_main.logfile;
const mutinyipc = dll_main.mutinyipc;
