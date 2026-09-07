pub const enable_mutiny_test_class = false;

const global = struct {
    var hinstance: win32.HINSTANCE = undefined;

    var thread_id: u32 = 0;
    var file_arena: std.heap.ArenaAllocator = undefined;
    var mods_path_buf: [appdata.max_path]u16 = undefined;
    var mods_path: ModsPath = undefined;
    var last_post_result: mainthread.PostResult = undefined;
    var tick_mode: TickMode = undefined;

    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_dumping: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };
};

const TickMode = union(enum) {
    subclass_window,
    update_mods: struct {
        last_error: ?UpdateModsError,
    },
};

const TimerId = enum(win32.WPARAM) {
    tick,
    rerun,
    _,
};
const init_update_ms = 200;
const update_mods_ms = 1000;

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (0 == global.paniced_threads_logging.fetchAdd(1, .seq_cst)) {
        std.log.err("panic: {s}", .{msg});
    }
    if (0 == global.paniced_threads_dumping.fetchAdd(1, .seq_cst)) {
        const log_file, const maybe_open_log_error = logfile.global.get();
        _ = maybe_open_log_error;
        // no buffer so we flush as soon as possible so as not to lose any output
        var file_writer = log_file.writer(&.{});
        writeStackTrace(
            error_return_trace,
            ret_addr,
            std.io.tty.detectConfig(log_file),
            &file_writer.interface,
        ) catch |err| file_writer.interface.print(
            "write stack trace failed with {t}\n",
            .{switch (err) {
                error.WriteFailed => file_writer.err orelse error.Unexpected,
                else => |e| e,
            }},
        ) catch {};
    }
    const current_thread_id = win32.GetCurrentThreadId();
    if (current_thread_id == global.thread_id) {
        if (0 == global.paniced_threads_msgboxing.fetchAdd(1, .seq_cst)) {
            var buf: [200]u8 = undefined;
            if (std.fmt.bufPrintZ(&buf, "{s}", .{msg})) |msg_z| {
                _ = win32.MessageBoxA(null, msg_z, "Mutiny Panic", .{});
            } else |_| {
                _ = win32.MessageBoxA(null, "message too long", "Mutiny.dll Panic", .{});
            }
        }
        if (win32.IsDebuggerPresent() != 0) @breakpoint();
        win32.ExitThread(0x8071540);
    }
    std.log.err(
        "panic on thread {} (not the mutiny thread), raising an exception for the game's crash handler",
        .{current_thread_id},
    );
    if (win32.IsDebuggerPresent() != 0) @breakpoint();
    win32.RaiseException(
        mutiny_panic_exception_code,
        win32.EXCEPTION_NONCONTINUABLE,
        0,
        null,
    );
    unreachable; // RaiseException should be noreturn when passed EXCEPTION_NONCONTINUABLE,
}

const mutiny_panic_exception_code: u32 = 0xE0000000 | 0x4D544E59;

fn writeStackTrace(
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
    tty_config: std.io.tty.Config,
    writer: *std.Io.Writer,
) !void {
    if (error_return_trace) |trace| {
        if (std.debug.getSelfDebugInfo()) |debug_info| {
            try std.debug.writeStackTrace(
                trace.*,
                writer,
                debug_info,
                tty_config,
            );
        } else |err| try writer.print(
            "getSelfDebugInfo for error trace faield with {s}\n",
            .{@errorName(err)},
        );
    }
    try std.debug.dumpCurrentStackTraceToWriter(ret_addr orelse @returnAddress(), writer);
    try writer.flush();
}

pub const mutiny_options: mainthread.Options = .{ .onUpdate = mainthread.onUpdate };

pub const std_options: std.Options = .{
    .logFn = log,
    .log_level = .info,
};
pub export fn _DllMainCRTStartup(
    hinst: win32.HINSTANCE,
    reason: u32,
    reserved: *anyopaque,
) callconv(.winapi) win32.BOOL {
    _ = reserved;
    switch (reason) {
        win32.DLL_PROCESS_ATTACH => {
            global.hinstance = hinst;
            // !!! WARNING !!! do not log here...logging uses APIs that we probably
            // aren't supposed to call at this phase.
            if (false) win32.OutputDebugStringW(win32.L("mutiny: proces attach\n"));
        },
        win32.DLL_THREAD_ATTACH => {
            std.debug.assert(global.hinstance == hinst);
        },
        win32.DLL_THREAD_DETACH => {},
        win32.DLL_PROCESS_DETACH => {
            // std.log.info("process detach", .{});
            // I don't think I need to lock the global mutex here
            // restoreAllWindows();
            // global.arena_instance.deinit();
        },
        else => unreachable,
    }
    return 1; // success
}

// fn on_vectored_exception(maybe_e: ?*win32.EXCEPTION_POINTERS) callconv(.winapi) i32 {
//     const e = maybe_e orelse {
//         std.log.err("exception! no info", .{});
//         return 0; // EXCEPTION_CONTINUE_SEARCH
//     };
//     const first_record = e.ExceptionRecord orelse {
//         std.log.err("exception! no records", .{});
//         return 0; // EXCEPTION_CONTINUE_SEARCH
//     };
//     switch (first_record.ExceptionCode) {
//         0x406d1388, // used for naming threads
//         => return 0, // EXCEPTION_CONTINUE_SEARCH
//         else => {},
//     }
//     std.log.err("exception! records:", .{});
//     var r = first_record;
//     while (true) {
//         std.log.err(
//             "  code={} (0x{0x}) flags=0x{x} address=0x{x}",
//             .{ r.ExceptionCode, r.ExceptionFlags, @intFromPtr(r.ExceptionAddress) },
//         );
//         r = r.ExceptionRecord orelse break;
//     }
//     return 0; // EXCEPTION_CONTINUE_SEARCH
// }

comptime {
    @export(&MutinyMain, .{ .name = mutinyipc.main_export_name });
}
fn MutinyMain(context: ?*anyopaque) callconv(.winapi) u32 {
    _ = context;
    std.log.info("MutinyMain", .{});
    std.log.info("module \"Mutiny.dll\" at 0x{x}", .{@intFromPtr(global.hinstance)});

    const mutex = blk: {
        var mutex_name_buf: [40]u16 = undefined;
        const mutex_name: [:0]u16 = blk_name: {
            var buf_utf8: [40]u8 = undefined;
            const utf8 = std.fmt.bufPrint(
                &buf_utf8,
                "Local\\mutiny-{}",
                .{win32.GetCurrentProcessId()},
            ) catch unreachable;
            const mutex_name_len = std.unicode.wtf8ToWtf16Le(&mutex_name_buf, utf8) catch unreachable;
            mutex_name_buf[mutex_name_len] = 0;
            break :blk_name mutex_name_buf[0..mutex_name_len :0];
        };

        const mutex = win32.CreateMutexW(null, 0, mutex_name) orelse {
            std.log.err("CreateMutex failed, error={f}", .{win32.GetLastError()});
            return 0xffffffff;
        };
        switch (win32.WaitForSingleObject(mutex, 0)) {
            @intFromEnum(win32.WAIT_OBJECT_0) => std.log.info("mutex '{f}' acquired", .{fmtW(mutex_name)}),
            @intFromEnum(win32.WAIT_ABANDONED) => std.log.info(
                "a previous Mutiny thread died here, taking over",
                .{},
            ),
            @intFromEnum(win32.WAIT_TIMEOUT) => {
                std.log.info("another Mutiny thread is already serving this process", .{});
                return 0;
            },
            else => |result| {
                std.log.err(
                    "wait on mutex '{f}' failed, result={d}, error={f}",
                    .{ fmtW(mutex_name), result, win32.GetLastError() },
                );
                return 0xffffffff;
            },
        }
        break :blk mutex;
    };
    defer {
        if (0 == win32.ReleaseMutex(mutex)) win32.panicWin32("ReleaseMutex", win32.GetLastError());
        win32.closeHandle(mutex);
    }

    // we're now considered the sole owner of all our global data
    global.thread_id = win32.GetCurrentThreadId();
    defer global.thread_id = 0;
    global.file_arena = .init(std.heap.page_allocator);
    defer {
        std.debug.assert(arenaIsClear(&global.file_arena));
        global.file_arena.deinit();
    }

    const name = switch (logfile.global.getName()) {
        .success => |s| s,
        .err => |err| {
            std.log.err("{f}", .{err});
            std.log.err("unable to get name, exiting since we use the name to filter which mods we run", .{});
            return 0xffffffff;
        },
    };
    const localappdata = appdata.get() orelse {
        std.log.err("no LOCALAPPDATA environment variable, don't know where to find mods", .{});
        return 0xffffffff;
    };
    global.mods_path = switch (appdata.format(
        &global.mods_path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("mods") },
    )) {
        .ok => |p| .{ .slice = p },
        .too_long => {
            std.log.err(
                "mods path too long (LOCALAPPDATA is {} chars, exe name '{f}' is {} chars",
                .{ localappdata.len, fmtW(name), name.len },
            );
            return 0xffffffff;
        },
    };

    {
        const wc: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = global.hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = win32.L(mutinyipc.window_class_name),
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&wc)) switch (win32.GetLastError()) {
            .ERROR_CLASS_ALREADY_EXISTS => {
                std.log.info("window class: already exists", .{});
            },
            else => |e| win32.panicWin32("RegisterClassEx", e),
        } else {
            std.log.info("window class: newly created", .{});
        }
    }

    const hwnd = win32.CreateWindowExW(
        .{},
        win32.L(mutinyipc.window_class_name),
        null,
        .{},
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        global.hinstance,
        null,
    ) orelse win32.panicWin32("CreateWindowEx", win32.GetLastError());
    defer if (0 == win32.DestroyWindow(hwnd)) win32.panicWin32(
        "DestroyWindow",
        win32.GetLastError(),
    );
    std.log.info("window 0x{x} created", .{@intFromPtr(hwnd)});

    // if (win32.AddVectoredExceptionHandler(1, on_vectored_exception)) |_| {
    //     std.log.info("AddVectoredExceptionHandler success", .{});
    // } else {
    //     std.log.err("AddVectoredExceptionHandler failed, error={f}", .{win32.GetLastError()});
    // }

    global.last_post_result = .posted;
    defer global.last_post_result = .posted;

    global.tick_mode = .subclass_window;
    if (0 == win32.SetTimer(
        hwnd,
        @intFromEnum(TimerId.tick),
        init_update_ms,
        null,
    )) {
        std.log.err("SetTimer(initial) failed, error={f}", .{win32.GetLastError()});
        return 0xffffffff;
    }

    while (true) {
        var msg: win32.MSG = undefined;
        const result = win32.GetMessageW(&msg, null, 0, 0);
        if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
        if (result == 0) {
            if (mainthread.mutinyThreadDetach()) {
                std.log.info("got WM_QUIT, exiting the mutiny thread", .{});
                break;
            }
            std.log.err("got WM_QUIT, but can't detach main thread", .{});
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }

    return 0;
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

fn parseBuiltin(
    writer: *std.Io.Writer,
    builtin_name: []const u8,
    args: *mutinyipc.StringList,
) error{ Reported, WriteFailed }!Builtin {
    const builtin_script = std.meta.stringToEnum(
        Builtin,
        builtin_name[1..],
    ) orelse return reportError(writer, "unknown builtin script '{s}'", .{builtin_name});

    var arg_count: usize = 0;
    while (args.next() catch return reportError(
        writer,
        "malformed run-script arguments",
        .{},
    )) |_| {
        arg_count += 1;
    }
    if (arg_count != 0) return reportError(
        writer,
        "builtin script '{s}' takes no arguments but got {}",
        .{ builtin_name, arg_count },
    );
    return builtin_script;
}

fn addScript(
    pid: u32,
    pipe: win32.HANDLE,
    writer: *std.Io.Writer,
    name_w: []const u16,
    args: *mutinyipc.StringList,
) error{ Reported, WriteFailed }!void {
    const name_utf8_len = std.unicode.calcWtf8Len(name_w);
    if (name_utf8_len > ModNameSlice.max_len) return reportError(
        writer,
        "script name is {} bytes, too long (max {})",
        .{ name_utf8_len, ModNameSlice.max_len },
    );
    if (name_w.len == 0) return reportError(writer, "script name is empty", .{});
    for (name_w) |c| switch (c) {
        '\\', '/', ':' => return reportError(
            writer,
            "script name '{f}' must be a name, not a path",
            .{fmtW(name_w)},
        ),
        else => {},
    };
    if (std.mem.eql(u16, name_w, win32.L(".")) or std.mem.eql(u16, name_w, win32.L(".."))) {
        return reportError(writer, "script name '{f}' is not a file", .{fmtW(name_w)});
    }

    var name_buf: [ModNameSlice.max_len]u8 = undefined;
    std.debug.assert(name_utf8_len == std.unicode.wtf16LeToWtf8(&name_buf, name_w));
    const name_a = name_buf[0..name_utf8_len];
    const script_name = ModNameSlice.init(name_a) orelse unreachable;

    const request: mainthread.ScriptRequest = blk: {
        if (name_w[0] == '@') break :blk .{
            .builtin = try parseBuiltin(writer, name_a, args),
        };

        if (args.next() catch return reportError(
            writer,
            "malformed run-script arguments",
            .{},
        )) |_| return reportError(
            writer,
            "script '{s}' was given arguments but scripts do not take arguments yet",
            .{name_a},
        );

        const localappdata = appdata.get() orelse return reportError(
            writer,
            "no LOCALAPPDATA environment variable",
            .{},
        );
        const app_name = switch (logfile.global.getName()) {
            .success => |s| s,
            .err => |err| return reportError(writer, "{f}", .{err}),
        };
        var path_buf: [appdata.max_path]u16 = undefined;
        const path = switch (appdata.format(&path_buf, localappdata, &.{
            win32.L("mutiny"),
            win32.L("app"),
            app_name,
            win32.L("scripts"),
            name_w,
        })) {
            .ok => |p| p,
            .too_long => return reportError(
                writer,
                "path for script '{f}' is too long",
                .{fmtW(name_w)},
            ),
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
        std.debug.assert(arenaIsClear(&global.file_arena));
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
        break :blk .{ .file = text };
    };
    defer _ = global.file_arena.reset(.retain_capacity);

    mainthread.mutinyThreadQueueScript(pid, pipe, script_name, request) catch return reportError(
        writer,
        "out of memory creating script '{f}'",
        .{fmtW(name_w)},
    );

    mainthread.mutinyThreadPostRun(&global.last_post_result);
    switch (global.last_post_result) {
        .posted => {},
        .not_ready => std.log.info(
            "script '{s}' scheduled but main thread not ready yet",
            .{name_a},
        ),
        .post_error => std.log.info(
            "script '{s}' scheduled but main thread post is failing",
            .{name_a},
        ),
    }
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

    queued = modfiles.deleteStale() or queued;
    if (queued) mainthread.mutinyThreadPostRun(&global.last_post_result);

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

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .mono_gchandle) return;

    const level_txt = comptime message_level.asText();
    const scope_suffix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";
    const level_scope = level_txt ++ scope_suffix;

    const log_file, const maybe_open_error = logfile.global.get();
    var buffer: [1024]u8 = undefined;
    var file_writer = log_file.writer(&buffer);

    logfile.global.write_log_mutex.lock();
    defer logfile.global.write_log_mutex.unlock();
    writeFlushLog(level_scope ++ "|" ++ format, args, &file_writer.interface, maybe_open_error) catch std.debug.panic(
        "write log failed with {s}",
        .{@errorName(file_writer.err orelse error.Unexpected)},
    );
}

fn writeFlushLog(
    comptime format: []const u8,
    args: anytype,
    writer: *std.Io.Writer,
    maybe_open_error: ?logfile.OpenLogError,
) error{WriteFailed}!void {
    if (maybe_open_error) |open_error| {
        try logfile.writeLogPrefix(writer);
        try writer.print("{f}", .{open_error});
    }
    try logfile.writeLogPrefix(writer);
    try writer.print(format ++ "\n", args);
    try writer.flush();
}

fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CREATE => {
            mainthread.mutinyThreadSetHwnd(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            mainthread.mutinyThreadUnsetHwnd(hwnd);
            return 0;
        },
        win32.WM_CLOSE => {
            // don't call DefWindowProc, it calls DestroyWindow but we do that ourselves
            // in a defer.
            return 0;
        },
        win32.WM_TIMER => {
            switch (@as(TimerId, @enumFromInt(wparam))) {
                .tick => timerTick(hwnd),
                .rerun => {
                    if (0 == win32.KillTimer(hwnd, @intFromEnum(TimerId.rerun))) win32.panicWin32("KillTimer", win32.GetLastError());
                    mainthread.mutinyThreadPostRun(&global.last_post_result);
                },
                else => {},
            }
            return 0;
        },
        // WM_USER + ... (private messages)
        mainthread.wm_schedule_rerun => {
            const ms = std.math.cast(u32, wparam) orelse std.math.maxInt(u32);
            if (0 == win32.SetTimer(hwnd, @intFromEnum(TimerId.rerun), ms, null)) {
                std.log.err("SetTimer(rerun) failed, error={f}", .{win32.GetLastError()});
                mainthread.mutinyThreadPostRun(&global.last_post_result);
            }
            return 0;
        },
        win32.WM_COPYDATA => {
            const copy_data: *const win32.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (copy_data.dwData != mutinyipc.wm_copydata_run_script) {
                std.log.info("ignoring WM_COPYDATA with dwData 0x{x}", .{copy_data.dwData});
                return 0x7fffffff;
            }
            if (copy_data.cbData == 0 or copy_data.cbData % 2 != 0) {
                std.log.info("bad run-script cbData {}", .{copy_data.cbData});
                return 0x7fffffff;
            }
            const request_bytes = @as([*]const u8, @ptrCast(copy_data.lpData.?))[0..copy_data.cbData];
            const request: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, request_bytes));
            var strings = mutinyipc.StringList.init(request) catch {
                std.log.info("malformed run-script request", .{});
                return 0x7fffffff;
            };
            const script = blk: {
                const maybe_name = strings.next() catch {
                    std.log.info("malformed run-script request strings", .{});
                    return 0x7fffffff;
                };
                break :blk maybe_name orelse {
                    std.log.info("run-script request has no script name", .{});
                    return 0x7fffffff;
                };
            };
            const pid: u32 = std.math.cast(u32, wparam) orelse {
                std.log.info("WM_COPYDATA wParam {} is not a valid 32-bit pid", .{wparam});
                return 0x7fffffff;
            };
            std.log.info(
                "run-script '{f}' requested by pid {}",
                .{ fmtW(script), pid },
            );

            var pipe_name_buf: [mutinyipc.pipe_name_buf_len]u16 = undefined;
            const pipe_name = mutinyipc.formatClientPipeName(&pipe_name_buf, pid);
            const pipe = win32.CreateFileW(
                pipe_name,
                .{ .FILE_WRITE_DATA = 1 },
                .{},
                null,
                .OPEN_EXISTING,
                .{},
                null,
            );
            if (pipe == win32.INVALID_HANDLE_VALUE) {
                std.log.err("connect to '{f}' failed, error={f}", .{
                    fmtW(pipe_name),
                    win32.GetLastError(),
                });
                return 0x7fffffff;
            }
            var pipe_owned = true;
            defer if (pipe_owned) win32.closeHandle(pipe);

            var pipe_file: std.fs.File = .{ .handle = pipe };
            var pipe_write_buf: [400]u8 = undefined;
            var pipe_writer = pipe_file.writerStreaming(&pipe_write_buf);
            const writer = &pipe_writer.interface;

            if (addScript(pid, pipe, writer, script, &strings)) {
                pipe_owned = false;
            } else |e| switch (e) {
                error.Reported => return mutinyipc.wm_copydata_result,
                error.WriteFailed => {
                    std.log.err("write to client pipe failed with {t}", .{pipe_writer.err.?});
                    return mutinyipc.wm_copydata_result;
                },
            }

            return mutinyipc.wm_copydata_result;
        },
        // WM_APP...
        mutinyipc.wm_heartbeat => return mutinyipc.heartbeat_result,
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
fn timerTick(hwnd: win32.HWND) void {
    mainthread.mutinyThreadOnTick(&global.last_post_result);
    switch (global.tick_mode) {
        .subclass_window => switch (mainthread.mutinyThreadSubclassUpdate()) {
            .keep_calling => {},
            .done => {
                if (0 == win32.SetTimer(
                    hwnd,
                    @intFromEnum(TimerId.tick),
                    update_mods_ms,
                    null,
                )) {
                    std.log.err("SetTimer() failed, error={f}", .{win32.GetLastError()});
                    return; // don't update mode, next tick will retry to set the timer
                }
                global.tick_mode = .{ .update_mods = .{ .last_error = null } };
            },
        },
        .update_mods => |*state| {
            const maybe_error = updateMods();
            if (maybe_error) |*new_error| {
                const same_error = if (state.last_error) |*le| new_error.eql(le) else false;
                if (!same_error) {
                    new_error.log(global.mods_path.slice);
                    state.last_error = new_error.*;
                    std.debug.assert(new_error.eql(&state.last_error.?));
                }
            }
        },
    }
}

const arenaIsClear = mainthread.arenaIsClear;

const fmtW = std.unicode.fmtUtf16Le;

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const mainthread = @import("mainthread");

const modfiles = @import("modfiles.zig");

const appdata = mainthread.appdata;
const logfile = mainthread.logfile;
const mutinyipc = mainthread.mutinyipc;

const Builtin = mainthread.Builtin;
const ModNameSlice = mainthread.ModNameSlice;
