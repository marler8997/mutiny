const global = struct {
    var mutex: Mutex = .{};
    var localappdata_resolved: bool = false;
    var localappdata: ?[]const u16 = null;
    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };
};

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (0 == global.paniced_threads_logging.fetchAdd(1, .seq_cst)) {
        std.log.err("panic: {s}", .{msg});
    }
    if (0 == global.paniced_threads_msgboxing.fetchAdd(1, .seq_cst)) {
        var buf: [200]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}", .{msg})) |msg_z| {
            _ = win32.MessageBoxA(null, msg_z, "MarlerMod Panic", .{});
        } else |_| {
            _ = win32.MessageBoxA(null, "message too long", "MarlerMod Panic", .{});
        }
    }
    // can't call this, results in:
    //     error: lld-link: undefined symbol: _tls_index
    // this must be because it uses a threadlocal variable "panic_stage"
    //std.builtin.default_panic(msg, error_return_trace, ret_addr);
    _ = error_return_trace;
    _ = ret_addr;
    @breakpoint();
    std.process.exit(0xff);
}

pub const std_options: std.Options = .{
    .logFn = log,
};
pub export fn _DllMainCRTStartup(
    hinst: win32.HINSTANCE,
    reason: u32,
    reserved: *anyopaque,
) callconv(.winapi) win32.BOOL {
    _ = hinst;
    _ = reserved;
    switch (reason) {
        win32.DLL_PROCESS_ATTACH => {
            // !!! WARNING !!! do not log here...logging uses APIs that we probably
            // aren't supposed to call at this phase.
            if (false) win32.OutputDebugStringW(win32.L("MarlerMod: proces attach\n"));

            // We'll spawn a thread so we can do our initialization outside the loader lock
            const thread = win32.CreateThread(null, 0, initThreadEntry, null, .{}, null) orelse {
                win32.OutputDebugStringW(win32.L("MarlerMod: CreateThread failed"));
                // TODO: how can we log the error code?
                return 1; // fail
            };
            win32.closeHandle(thread);
        },
        win32.DLL_THREAD_ATTACH => {},
        win32.DLL_THREAD_DETACH => {},
        win32.DLL_PROCESS_DETACH => {
            // I don't think I need to lock the global mutex here
            // restoreAllWindows();
            // global.arena_instance.deinit();
        },
        else => unreachable,
    }
    return 1; // success
}

fn initThreadEntry(context: ?*anyopaque) callconv(.winapi) u32 {
    _ = context;
    std.log.info("Init Thread running!", .{});

    loadMods();

    // TODO: how do we call .NET methods?

    // At this point we're running inside the game process
    // But we can't directly call Unity APIs yet - we need to hook into
    // the game's main thread

    // For now, just log success and prepare for the C# side to take over
    // In a full implementation, we would:
    // 1. Find the Mono/IL2CPP runtime
    // 2. Load our managed DLL (ScriptEngine.dll)
    // 3. Call into C# to set up the rest

    // std.log.info("Native initialization complete", .{});
    // std.log.info("TODO: Hook into Mono runtime and load managed DLL", .{});

    // _ = msgbox(.{}, "MarlerMod Init Thread", "InitThread running!", .{});
    return 0;
}

fn loadMods() void {
    const mod_path = "C:\\temp\\marlermods";
    std.log.info("loading mods from '{s}'...", .{mod_path});
    var dir = std.fs.cwd().openDir(mod_path, .{ .iterate = true }) catch |err| {
        std.log.err("open mod directory '{s}' failed with {s}", .{ mod_path, @errorName(err) });
        return;
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |err| {
        std.log.err("iterate mod directory '{s}' failed with {s}", .{ mod_path, @errorName(err) });
        return;
    }) |entry| {
        std.log.info("todo: load mod '{s}'", .{entry.name});
    }
}

// Export a function that the C# managed code can call
// This allows us to bridge between native and managed
export fn NativeLog(message: [*:0]const u8) callconv(.c) void {
    const msg = std.mem.span(message);
    std.log.info("{s}", .{msg});
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const scope_suffix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    const localappdata = blk: {
        global.mutex.lock();
        defer global.mutex.unlock();
        if (!global.localappdata_resolved) {
            global.localappdata = std.process.getenvW(win32.L("localappdata"));
            global.localappdata_resolved = true;
        }
        break :blk global.localappdata;
    } orelse {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        if (true) @panic("no localappdata");
        // no localappdata, guess we won't log anything
        return;
    };

    const log_size = log_size_blk: {
        const log_file = openLog(localappdata) orelse {
            if (true) @panic("here");
            // TODO: should we do anything?
            return;
        };
        defer log_file.close();

        const name: []const u16 = blk: {
            const p = getImagePathName() orelse break :blk win32.L("?");
            break :blk getBasename(p);
        };

        var out_buffer: [1024]u8 = undefined;
        var file_writer = log_file.writer(&out_buffer);
        const writer = &file_writer.interface;
        // TODO: maybe we should also log to OutputDebug?

        {
            var time: win32.SYSTEMTIME = undefined;
            win32.GetSystemTime(&time);
            writer.print(
                "{:0>2}:{:0>2}:{:0>2}.{:0>3}|{}|{}|{f}|" ++ level_txt ++ scope_suffix ++ "|",
                .{
                    time.wHour,                  time.wMinute,               time.wSecond,                 time.wMilliseconds,
                    win32.GetCurrentProcessId(), win32.GetCurrentThreadId(), std.unicode.fmtUtf16Le(name),
                },
            ) catch |err| errExit("log failed with {s}", .{@errorName(err)});
        }
        writer.print(format ++ "\n", args) catch |err| errExit("log failed with {s}", .{@errorName(err)});
        writer.flush() catch |err| errExit("flush log file failed with {s}", .{@errorName(err)});

        var file_size: win32.LARGE_INTEGER = undefined;
        if (0 == win32.GetFileSizeEx(log_file.handle, &file_size))
            break :log_size_blk 0;
        break :log_size_blk file_size.QuadPart;
    };

    // roll at 1 MB
    const roll_size = 1 * 1024 * 1024; // 1 MB
    if (log_size >= roll_size) {
        rollLog(localappdata);
    }
}

const max_log_path = 2000;

fn makeLocalAppDataPath(
    path_buf: []u16,
    localappdata: []const u16,
    sub_path: []const u16,
) ?[:0]const u16 {
    if (localappdata.len + 1 + sub_path.len >= path_buf.len) {
        // oh well
        return null;
    }
    @memcpy(path_buf[0..localappdata.len], localappdata);
    path_buf[localappdata.len] = '\\';
    @memcpy(path_buf[localappdata.len + 1 ..][0..sub_path.len], sub_path);
    path_buf[localappdata.len + 1 + sub_path.len] = 0;
    return path_buf.ptr[0 .. localappdata.len + 1 + sub_path.len :0];
}

fn openLog(localappdata: []const u16) ?std.fs.File {
    // var path_buf: [max_log_path]u16 = undefined;
    // const path = makeLocalAppDataPath(&path_buf, localappdata, win32.L("marlermod\\log.txt")) orelse return null;
    _ = localappdata;
    const path = win32.L("C:\\temp\\marlermod.log");

    // if (getDirname(path)) |log_dir| {
    //     _ = log_dir;
    //     @panic("todo");
    // }

    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const handle = win32.CreateFileW(
            path,
            .{
                //.FILE_WRITE_DATA = 1,
                .FILE_APPEND_DATA = 1,
                //.FILE_WRITE_EA = 1,
                //.FILE_WRITE_ATTRIBUTES = 1,
                //.READ_CONTROL = 1,
                //.SYNCHRONIZE = 1,
            },
            .{ .READ = 1 },
            null,
            .OPEN_ALWAYS,
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) switch (win32.GetLastError()) {
            .ERROR_SHARING_VIOLATION => {
                if (attempt >= 5) return null;
                // try again
                win32.Sleep(1);
                continue;
            },
            else => |e| {
                if (attempt >= 5) return null;
                // try again
                win32.Sleep(1);
                _ = e;
                //std.debug.panic("CreateFile failed, error={}", .{e}),
                continue;
            },
        };
        return .{ .handle = handle };
    }
}

fn rollLog(localappdata: []const u16) void {
    var src_buf: [max_log_path]u16 = undefined;
    const src = makeLocalAppDataPath(&src_buf, localappdata, win32.L("marlermod\\log.txt")) orelse return;
    var dst_buf: [max_log_path + 2]u16 = undefined;
    const dst = makeLocalAppDataPath(&dst_buf, localappdata, win32.L("marlermod\\log.1.txt")) orelse return;
    _ = win32.MoveFileExW(src, dst, .{ .REPLACE_EXISTING = 1 });
}

fn getImagePathName() ?[]const u16 {
    const str = &std.os.windows.peb().ProcessParameters.ImagePathName;
    if (str.Buffer) |buffer|
        return buffer[0..@divTrunc(str.Length, 2)];
    return null;
}
fn getBasename(path: []const u16) []const u16 {
    for (1..path.len) |i| {
        if (path[path.len - i] == '\\')
            return path[path.len - i + 1 ..];
    }
    return path;
}
fn getDirname(path: []const u16) ?[]const u16 {
    for (1..path.len) |i| {
        if (path[path.len - i] == '\\')
            return path[0 .. path.len - i];
    }
    return null;
}

fn msgbox(
    style: win32.MESSAGEBOX_STYLE,
    title: [*:0]const u8,
    comptime fmt: []const u8,
    args: anytype,
) win32.MESSAGEBOX_RESULT {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const msg = std.fmt.allocPrintSentinel(arena, fmt, args, 0) catch |err| switch (err) {
        error.OutOfMemory => {
            _ = win32.MessageBoxA(null, "Out of memory", title, .{});
            win32.ExitProcess(0xff);
        },
    };
    //defer global.arena.free(msg);
    return win32.MessageBoxA(null, msg, title, style);
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    //if (global.log_file) |f| {
    //    f.writer().writeAll("fatal: ") catch { };
    //    f.writer().print(fmt, args) catch { };
    //}
    _ = msgbox(.{}, "MarlerMod.dll: Fatal Error", fmt, args);
    win32.ExitProcess(0xff);
}

const std = @import("std");
const win32 = @import("win32").everything;
const Mutex = @import("Mutex.zig");
