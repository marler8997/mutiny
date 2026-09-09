const global = struct {
    var context: Context = undefined;
    var file_arena: std.heap.ArenaAllocator = undefined;
    var mods_path_buf: [appdata.max_path]u16 = undefined;
    var mods_path: ModsPath = undefined;

    var wake: win32.HANDLE = undefined;
    var requests_mutex: Mutex = .{};
    var requests: std.DoublyLinkedList = .{};
    var request_pool: Pool(LoadRequest) = .{};
};

const mods_dir_retry_ms = 1000;

pub const Context = struct {
    name: []const u16,
    localappdata: []const u16,
};

const LoadRequest = struct {
    list_node: std.DoublyLinkedList.Node,
    pid: u32,
    pipe: win32.HANDLE,
    name: BoundedArray(u8, ModNameSlice.max_len),

    fn nameSlice(request: *const LoadRequest) ModNameSlice {
        return .{ .ptr = &request.name.buffer, .len = request.name.len };
    }
};

pub fn requestLoad(pid: u32, pipe: win32.HANDLE, script_name: ModNameSlice) error{OutOfMemory}!void {
    const request = try global.request_pool.create();
    request.* = .{
        .list_node = .{},
        .pid = pid,
        .pipe = pipe,
        .name = .{ .len = script_name.len, .buffer = undefined },
    };
    @memcpy(request.name.buffer[0..script_name.len], script_name.slice());
    {
        global.requests_mutex.lock();
        defer global.requests_mutex.unlock();
        global.requests.append(&request.list_node);
    }
    if (0 == win32.SetEvent(global.wake)) win32.panicWin32("SetEvent", win32.GetLastError());
}

fn takeLoadRequest() ?*LoadRequest {
    global.requests_mutex.lock();
    defer global.requests_mutex.unlock();
    const node = global.requests.first orelse return null;
    global.requests.remove(node);
    return @fieldParentPtr("list_node", node);
}

pub fn spawn(context: Context) error{Spawn}!win32.HANDLE {
    global.context = context;
    global.wake = win32.CreateEventW(null, 0, 0, null) orelse {
        std.log.err("CreateEvent for the io thread failed, error={f}", .{win32.GetLastError()});
        return error.Spawn;
    };
    global.mods_path = switch (appdata.format(
        &global.mods_path_buf,
        context.localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), context.name, win32.L("mods") },
    )) {
        .ok => |p| .{ .slice = p },
        .too_long => {
            std.log.err(
                "mods path too long (LOCALAPPDATA is {} chars, exe name '{f}' is {} chars",
                .{ context.localappdata.len, fmtW(context.name), context.name.len },
            );
            return error.Spawn;
        },
    };
    return win32.CreateThread(null, mutinyipc.thread_stack_size, threadMain, null, .{}, null) orelse {
        std.log.err("CreateThread for the io thread failed, error={f}", .{win32.GetLastError()});
        return error.Spawn;
    };
}

fn threadMain(param: ?*anyopaque) callconv(.winapi) u32 {
    _ = param;

    global.file_arena = .init(std.heap.page_allocator);
    defer {
        std.debug.assert(arenaIsClear(&global.file_arena));
        global.file_arena.deinit();
    }

    const wake = global.wake;
    var mods_watch: ModsWatch = .{};
    defer mods_watch.close();
    mods_watch.open();

    while (true) {
        while (takeLoadRequest()) |request| {
            defer global.request_pool.destroy(request);
            loadScript(global.context.name, global.context.localappdata, request);
        }

        var handles: [2]?win32.HANDLE = .{ wake, null };
        var handle_count: u32 = 1;
        if (mods_watch.handle) |handle| {
            handles[1] = handle;
            handle_count = 2;
        }
        const timeout_ms: u32 = if (mods_watch.handle == null) mods_dir_retry_ms else win32.INFINITE;

        switch (win32.WaitForMultipleObjects(handle_count, &handles, 0, timeout_ms)) {
            @intFromEnum(win32.WAIT_OBJECT_0) => {},
            @intFromEnum(win32.WAIT_OBJECT_0) + 1 => mods_watch.onChanged(),
            @intFromEnum(win32.WAIT_TIMEOUT) => mods_watch.open(),
            else => |result| std.debug.panic(
                "WaitForMultipleObjects returned {} (error={f})",
                .{ result, win32.GetLastError() },
            ),
        }
    }
}

const ModsWatch = struct {
    handle: ?win32.HANDLE = null,
    no_dir_logged: bool = false,
    last_error: ?UpdateModsError = null,

    fn open(watch: *ModsWatch) void {
        std.debug.assert(watch.handle == null);
        const handle = win32.FindFirstChangeNotificationW(
            global.mods_path.slice,
            0,
            .{ .FILE_NAME = 1, .SIZE = 1, .LAST_WRITE = 1 },
        );
        if (handle == @intFromPtr(win32.INVALID_HANDLE_VALUE)) {
            switch (win32.GetLastError()) {
                .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {
                    if (!watch.no_dir_logged) {
                        std.log.info("no mods (directory '{f}' does not exist)", .{global.mods_path});
                        watch.no_dir_logged = true;
                    }
                },
                else => |e| std.log.err("FindFirstChangeNotification on '{f}' failed, error={f}", .{ global.mods_path, e }),
            }
            return;
        }
        watch.handle = @ptrFromInt(@as(usize, @bitCast(handle)));
        watch.no_dir_logged = false;
        std.log.info("watching '{f}'", .{global.mods_path});
        watch.scan();
    }

    fn close(watch: *ModsWatch) void {
        const handle = watch.handle orelse return;
        watch.handle = null;
        if (0 == win32.FindCloseChangeNotification(@bitCast(@intFromPtr(handle)))) win32.panicWin32(
            "FindCloseChangeNotification",
            win32.GetLastError(),
        );
    }

    fn onChanged(watch: *ModsWatch) void {
        const handle = watch.handle.?;
        if (0 == win32.FindNextChangeNotification(@bitCast(@intFromPtr(handle)))) {
            std.log.err("FindNextChangeNotification failed, error={f}", .{win32.GetLastError()});
            watch.close();
            watch.scan();
            return;
        }
        watch.scan();
    }

    fn scan(watch: *ModsWatch) void {
        const maybe_error = updateMods();
        if (maybe_error) |*new_error| {
            const same_error = if (watch.last_error) |*le| new_error.eql(le) else false;
            if (!same_error) {
                new_error.log(global.mods_path.slice);
                watch.last_error = new_error.*;
            }
            switch (new_error.*) {
                .open_mods_dir_error => |e| if (e == error.FileNotFound) watch.close(),
                .iterate_mods_dir_error => {},
            }
        } else {
            watch.last_error = null;
        }
    }
};

fn loadScript(name: []const u16, localappdata: []const u16, request: *const LoadRequest) void {
    const pipe_file: std.fs.File = .{ .handle = request.pipe };
    var pipe_write_buf: [400]u8 = undefined;
    var pipe_writer = pipe_file.writerStreaming(&pipe_write_buf);
    const writer = &pipe_writer.interface;

    std.debug.assert(arenaIsClear(&global.file_arena));
    defer _ = global.file_arena.reset(.retain_capacity);

    if (readScript(name, localappdata, request, writer)) |text| {
        dll_main.ioThreadQueueScript(request.pid, request.pipe, request.nameSlice(), .{ .file = text }) catch {
            reportError(writer, "out of memory creating script '{s}'", .{request.name.slice()}) catch {};
            win32.closeHandle(request.pipe);
        };
    } else |err| switch (err) {
        error.Reported => win32.closeHandle(request.pipe),
        error.WriteFailed => {
            std.log.err("write to client pipe failed with {t}", .{pipe_writer.err.?});
            win32.closeHandle(request.pipe);
        },
    }
}

fn readScript(
    name: []const u16,
    localappdata: []const u16,
    request: *const LoadRequest,
    writer: *std.Io.Writer,
) error{ Reported, WriteFailed }![]const u8 {
    var name_w_buf: [ModNameSlice.max_len]u16 = undefined;
    const name_w_len = std.unicode.wtf8ToWtf16Le(&name_w_buf, request.name.slice()) catch unreachable;
    const name_w = name_w_buf[0..name_w_len];

    var path_buf: [appdata.max_path]u16 = undefined;
    const path = switch (appdata.format(&path_buf, localappdata, &.{
        win32.L("mutiny"),
        win32.L("app"),
        name,
        win32.L("scripts"),
        name_w,
    })) {
        .ok => |p| p,
        .too_long => return reportError(writer, "path for script '{s}' is too long", .{request.name.slice()}),
    };

    const prefixed = std.os.windows.wToPrefixedFileW(null, path) catch |err| return reportError(
        writer,
        "bad script path '{f}', {t}",
        .{ fmtW(path), err },
    );
    var file = std.fs.cwd().openFileW(prefixed.span(), .{}) catch |err| return reportError(
        writer,
        "open '{f}' failed with {t}",
        .{ fmtW(path), err },
    );
    defer file.close();
    const file_size64 = file.getEndPos() catch |err| return reportError(
        writer,
        "get size of '{f}' failed with {t}",
        .{ fmtW(path), err },
    );
    const file_size = std.math.cast(usize, file_size64) orelse return reportError(
        writer,
        "script '{f}' is too big ({} bytes)",
        .{ fmtW(path), file_size64 },
    );
    const text = global.file_arena.allocator().alloc(u8, file_size) catch return reportError(
        writer,
        "out of memory reading '{f}' ({} bytes)",
        .{ fmtW(path), file_size },
    );
    readFile(file, text) catch |err| return reportError(
        writer,
        "read '{f}' failed with {t}",
        .{ fmtW(path), err },
    );
    return text;
}

fn reportError(
    writer: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) error{ WriteFailed, Reported } {
    writer.print(fmt ++ "\n", args) catch return error.WriteFailed;
    writer.flush() catch return error.WriteFailed;
    return error.Reported;
}

const UpdateModsError = union(enum) {
    open_mods_dir_error: std.fs.Dir.OpenError,
    iterate_mods_dir_error: std.fs.Dir.Iterator.Error,

    pub fn eql(left: *const UpdateModsError, right: *const UpdateModsError) bool {
        return switch (left.*) {
            .open_mods_dir_error => |left_err| switch (right.*) {
                .open_mods_dir_error => |right_err| left_err == right_err,
                else => false,
            },
            .iterate_mods_dir_error => |left_err| switch (right.*) {
                .iterate_mods_dir_error => |right_err| left_err == right_err,
                else => false,
            },
        };
    }
    pub fn log(err: *const UpdateModsError, mods_path: [:0]const u16) void {
        switch (err.*) {
            .open_mods_dir_error => |e| switch (e) {
                error.FileNotFound => std.log.info(
                    "no mods (directory '{f}' does not exist)",
                    .{fmtW(mods_path)},
                ),
                else => |e2| std.log.err(
                    "open '{f}' failed with {t}",
                    .{ fmtW(mods_path), e2 },
                ),
            },
            .iterate_mods_dir_error => |e| std.log.err(
                "iterate '{f}' failed with {t}",
                .{ fmtW(mods_path), e },
            ),
        }
    }
};

const ModsPath = struct {
    slice: if (builtin.os.tag == .windows) [:0]const u16 else [:0]const u8,
    pub fn format(path: ModsPath, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (builtin.os.tag == .windows) {
            try writer.print("{f}", .{fmtW(path.slice)});
        } else {
            try writer.writeAll(path.slice);
        }
    }

    pub fn open(path: ModsPath, options: std.fs.Dir.OpenOptions) !std.fs.Dir {
        if (builtin.os.tag == .windows) {
            const space = try std.os.windows.wToPrefixedFileW(null, path.slice);
            return try std.fs.cwd().openDirW(space.span(), options);
        } else {
            return try std.fs.cwd().openDirZ(path.slice, options);
        }
    }
};

fn updateMods() ?UpdateModsError {
    modfiles.markStale();

    if (false) std.log.info("loading mods from '{f}'...", .{global.mods_path});
    var dir = global.mods_path.open(.{ .iterate = true }) catch |err| {
        // TODO: should we try seeing if the mutiny folder even exists
        return .{ .open_mods_dir_error = err };
    };
    defer dir.close();

    var queued = false;

    var it = dir.iterate();
    while (it.next() catch |err| {
        std.log.err("iterate mod directory '{f}' failed with {s}", .{ global.mods_path, @errorName(err) });
        return .{ .iterate_mods_dir_error = err };
    }) |entry| {
        if (entry.kind != .file) continue;
        const mod_name = ModNameSlice.init(entry.name) orelse {
            std.log.err("mod name ({}) is too long (max is {})", .{ entry.name.len, ModNameSlice.max_len });
            continue;
        };
        std.debug.assert(arenaIsClear(&global.file_arena));
        defer _ = global.file_arena.reset(.retain_capacity);
        queued = modfiles.update(mod_name, readModFile(dir, entry.name)) or queued;
    }

    _ = modfiles.deleteStale() or queued;

    return null;
}

fn readModFile(dir: std.fs.Dir, entry_name: []const u8) modfiles.Update {
    var file = dir.openFile(entry_name, .{}) catch |err| return .{ .err = .{ .open_file = err } };
    defer file.close();
    const file_size64 = file.getEndPos() catch |err| return .{ .err = .{ .file_size = err } };
    const file_size = std.math.cast(usize, file_size64) orelse return .{ .err = .{ .file_too_big = file_size64 } };

    std.debug.assert(arenaIsClear(&global.file_arena));
    const content = global.file_arena.allocator().alloc(u8, file_size) catch return .{ .err = .out_of_memory };
    readFile(file, content) catch |err| return .{ .err = .{ .read_file = err } };
    return .{ .content = content };
}

fn readFile(file: std.fs.File, mem: []u8) (error{EndOfStream} || std.fs.File.ReadError)!void {
    var total_read: usize = 0;
    while (total_read != mem.len) {
        const last_read = try file.read(mem[total_read..]);
        if (last_read == 0) return error.EndOfStream;
        total_read += last_read;
    }
}

const arenaIsClear = dll_main.arenaIsClear;
const fmtW = std.unicode.fmtUtf16Le;

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const dll_main = @import("dll_main");

const modfiles = @import("modfiles.zig");

const appdata = dll_main.appdata;
const mutinyipc = dll_main.mutinyipc;

const BoundedArray = dll_main.BoundedArray;
const ModNameSlice = dll_main.ModNameSlice;
const Mutex = dll_main.Mutex;
const Pool = dll_main.Pool;
