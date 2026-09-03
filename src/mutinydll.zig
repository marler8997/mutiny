const global = struct {
    var hinstance: win32.HINSTANCE = undefined;
    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_dumping: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };

    var mods: std.DoublyLinkedList = .{};
    var scripts: std.DoublyLinkedList = .{};
};

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
        var buffer: [1024]u8 = undefined;
        var file_writer = log_file.writer(&buffer);
        writeStackTrace(
            error_return_trace,
            ret_addr,
            std.io.tty.detectConfig(log_file),
            &file_writer.interface,
        ) catch |err| file_writer.interface.print(
            "write stack trace failed with {t}",
            .{switch (err) {
                error.WriteFailed => file_writer.err orelse error.Unexpected,
                else => |e| e,
            }},
        ) catch {};
    }
    if (0 == global.paniced_threads_msgboxing.fetchAdd(1, .seq_cst)) {
        var buf: [200]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}", .{msg})) |msg_z| {
            _ = win32.MessageBoxA(null, msg_z, "Mutiny Panic", .{});
        } else |_| {
            _ = win32.MessageBoxA(null, "message too long", "Mutiny.dll Panic", .{});
        }
    }
    @breakpoint();
    win32.ExitThread(0x8071540);
}

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

const DotNetLib = struct {
    kind: dotnet.Kind,
    module: win32.HINSTANCE,
};
fn getDotNet(arg: struct {
    timeout_seconds: u32,
}) ?DotNetLib {
    const start = getNow();
    var attempt: u32 = 0;

    std.log.info(
        "attempting to load either {s} or {s} with {} second timeout",
        .{ dotnet.dll_name_mono, dotnet.dll_name_il2cpp, arg.timeout_seconds },
    );

    while (true) {
        if (initMono()) |module| return .{ .kind = .mono, .module = module };
        if (initIl2cpp()) |module| return .{ .kind = .il2cpp, .module = module };

        attempt += 1;
        const elapsed_nanos = getNow().since(start);
        const elapsed_seconds = @as(f32, @floatFromInt(elapsed_nanos)) / std.time.ns_per_s;
        if (elapsed_seconds >= @as(f32, @floatFromInt(arg.timeout_seconds))) {
            _ = fmtMsgbox(
                .{ .ICONHAND = 1 },
                "Mutiny Fatal Error",
                "failed to load neither mono nor il2cpp {} seconds ({} attempts)",
                .{ arg.timeout_seconds, attempt },
            );
            return null;
        }
        const sleep_ms = 10;
        if (false) std.log.info("sleeping for {} ms", .{sleep_ms});
        win32.Sleep(sleep_ms);
    }
}

fn initMono() ?win32.HINSTANCE {
    if (win32.GetModuleHandleW(win32.L(dotnet.dll_name_mono))) |mono_mod|
        return mono_mod;
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => {
            std.log.info("{s}: not found yet...", .{dotnet.dll_name_mono});
            return null;
        },
        else => |e| std.debug.panic("GetModule '{s}' failed, error={f}", .{ dotnet.dll_name_mono, e }),
    }
}

fn initIl2cpp() ?win32.HINSTANCE {
    if (win32.GetModuleHandleW(win32.L(dotnet.dll_name_il2cpp))) |mod|
        return mod;
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => {
            std.log.info("{s}: not found yet...", .{dotnet.dll_name_il2cpp});
            return null;
        },
        else => |e| std.debug.panic("GetModule '{s}' failed, error={f}", .{ dotnet.dll_name_il2cpp, e }),
    }
}

comptime {
    @export(&MutinyStart, .{ .name = mutinyipc.start_export_name });
}
fn MutinyStart(context: ?*anyopaque) callconv(.winapi) u32 {
    _ = context;
    std.log.info("Init Thread running!", .{});

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
    std.log.info("window 0x{x} created", .{@intFromPtr(hwnd)});

    const maybe_unity_version: ?UnityVersion = blk: {
        const module = win32.GetModuleHandleW(win32.L("UnityPlayer.dll")) orelse {
            std.log.info("unity version: unknown (UnityPlayer.dll is not loaded)", .{});
            break :blk null;
        };
        const version = UnityVersion.fromLoadedModule(module) catch break :blk null;
        std.log.info("unity version: {f}", .{version});
        break :blk version;
    };

    var mods_path_buf: [appdata.max_path]u16 = undefined;
    const mods_path = switch (appdata.format(
        &mods_path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("mods") },
    )) {
        .ok => |p| p,
        .too_long => {
            std.log.err(
                "mods path too long (LOCALAPPDATA is {} chars, exe name '{f}' is {} chars",
                .{ localappdata.len, fmtW(name), name.len },
            );
            return 0xffffffff;
        },
    };

    // if (win32.AddVectoredExceptionHandler(1, on_vectored_exception)) |_| {
    //     std.log.info("AddVectoredExceptionHandler success", .{});
    // } else {
    //     std.log.err("AddVectoredExceptionHandler failed, error={f}", .{win32.GetLastError()});
    // }

    const dotnet_lib = getDotNet(.{
        .timeout_seconds = 10,
    }) orelse return 0xffffffff;
    std.log.info("{s}: 0x{x}", .{ dotnet_lib.kind.dllName(), @intFromPtr(dotnet_lib.module) });

    const dotnet_funcs: dotnet.Funcs = blk: {
        var missing_proc: [:0]const u8 = undefined;
        break :blk dotnet.Funcs.init(&missing_proc, dotnet_lib.kind, dotnet_lib.module) catch {
            _ = fmtMsgbox(
                .{ .ICONHAND = 1 },
                "Mutiny Fatal Error",
                "{s} is missing proc '{s}'",
                .{ dotnet_lib.kind.dllName(), missing_proc },
            );
            return 0xffffffff;
        };
    };

    const root_domain = blk: {
        var attempt: u32 = 0;
        while (true) {
            attempt += 1;
            if (dotnet_funcs.get_root_domain()) |domain| {
                std.log.info("dotnet root domain found: 0x{x}", .{@intFromPtr(domain)});
                break :blk domain;
            }
            std.log.info("mono_get_root_domain returned NULL (attempt {})", .{attempt});
            const max_attempts = 30;
            if (attempt >= max_attempts) {
                std.log.err("unable to get dotnet root domain after {} attempts", .{max_attempts});
                return 0xffffffff;
            }
            std.Thread.sleep(std.time.ns_per_s * 1);
        }
    };

    // if we go to fast the process will intermittently crash
    // TODO: find a better way to do this, might need to inspect mono source to find it
    std.log.info("waiting a second for main process to initialize dotnet...", .{});
    std.Thread.sleep(std.time.ns_per_s * 1);

    // sanity check, this should be null before we call thread_attach
    switch (dotnet_lib.kind) {
        .mono => std.debug.assert(dotnet_funcs.domain_get() == null),
        .il2cpp => {}, // this crashes on il2cpp
    }

    // std.log.info("Attaching thread to dotnet domain...", .{});
    const thread = dotnet_funcs.thread_attach(root_domain) orelse {
        std.log.err("mono_thread_attach failed!", .{});
        return 0xffffffff;
    };
    std.log.info("thread attach success 0x{x}", .{@intFromPtr(thread)});
    defer {
        std.log.info("detaching thread 0x{x}", .{@intFromPtr(thread)});
        dotnet_funcs.thread_detach(thread);
    }

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(dotnet_funcs.domain_get() == root_domain);

    const il2cpp_layouts: il2cppclass.Layouts = switch (dotnet_funcs.kind) {
        .mono => undefined,
        .il2cpp => blk: {
            const unity_version = maybe_unity_version orelse {
                std.log.err("cannot verify il2cpp layout without the unity version", .{});
                return 0xffffffff;
            };
            const start = getNow();
            const layouts = il2cppclass.discover(&dotnet_funcs, unity_version) catch |err| {
                std.log.err("il2cpp layout could not be verified ({t})", .{err});
                return 0xffffffff;
            };
            std.log.info("il2cpp layout verified in {} ms", .{
                @divTrunc(getNow().since(start), std.time.ns_per_ms),
            });
            break :blk layouts;
        },
    };
    // only the test fixture writes to the runtime today, and it discovers its own layouts;
    // this call is the gate that refuses an unfamiliar layout before we run at all
    _ = il2cpp_layouts;

    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var last_update_mods_error: ?UpdateModsError = null;

    main_loop: while (true) {
        {
            var msg: win32.MSG = undefined;
            while (0 != win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE)) {
                if (msg.message == win32.WM_QUIT) {
                    std.log.info("got WM_QUIT, exiting the mutiny thread", .{});
                    break :main_loop;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        }

        var tests_scheduled = false;

        {
            const maybe_new_error = updateMods(
                .{ .slice = mods_path },
                &dotnet_funcs,
                scratch.allocator(),
                &tests_scheduled,
            );
            if (maybe_new_error) |*new_error| {
                const same_error = if (last_update_mods_error) |*le| new_error.eql(le) else false;
                if (!same_error) {
                    new_error.log(mods_path);
                }
            }
            last_update_mods_error = maybe_new_error;
        }

        if (!scratch.reset(.retain_capacity)) {
            std.log.warn("reset scratch allocator failed?", .{});
        }

        const scripts_sleep_time_ms = serviceScripts(&dotnet_funcs, &tests_scheduled);

        if (tests_scheduled) {
            std.log.info("@ScheduleTests requested! running...", .{});
            if (maybe_unity_version) |unity_version| Vm.runTests(&dotnet_funcs, unity_version) catch |err| {
                std.log.err("tests failed with {s}:", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                } else {
                    std.log.err("    no error trace", .{});
                }
            } else {
                std.log.err("canot run tests, no unity version", .{});
            }
        }

        // var sleep_time_ms: u64 = 5000;
        var sleep_time_ms: u64 = @min(1000, scripts_sleep_time_ms);
        const now = getNow();
        {
            var maybe_mod = global.mods.first;
            while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
                const mod: *Mod = @fieldParentPtr("list_node", list_node);
                sleep_time_ms = @min(sleep_time_ms, mod.nextYieldSleepMs(now));
            }
        }
        // std.log.info("sleep time ms {}", .{sleep_time_ms});
        switch (win32.MsgWaitForMultipleObjectsEx(
            0,
            null,
            @intCast(sleep_time_ms),
            win32.QS_ALLINPUT,
            .{},
        )) {
            @intFromEnum(win32.WAIT_OBJECT_0), @intFromEnum(win32.WAIT_TIMEOUT) => {},
            else => win32.panicWin32("MsgWaitForMultipleObjectsEx", win32.GetLastError()),
        }
    }

    return 0;
}

const Client = struct {
    pipe: win32.HANDLE,
    pid: u32,
};

const Builtin = enum { assemblies, decomp };

const Run = union(enum) {
    script: Mod.HaveText,
    builtin: Builtin,
};

fn parseBuiltin(
    writer: *std.Io.Writer,
    name: []const u8,
    args: *mutinyipc.StringList,
) error{ Reported, WriteFailed }!Builtin {
    const builtin_script = std.meta.stringToEnum(
        Builtin,
        name[1..],
    ) orelse return reportError(writer, "unknown builtin script '{s}'", .{name});

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
        .{ name, arg_count },
    );
    return builtin_script;
}

fn reportError(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{ WriteFailed, Reported } {
    writer.print(fmt ++ "\n", args) catch return error.WriteFailed;
    writer.flush() catch return error.WriteFailed;
    return error.Reported;
}

fn addScript(
    pid: u32,
    pipe: win32.HANDLE,
    writer: *std.Io.Writer,
    name_w: []const u16,
    args: *mutinyipc.StringList,
) error{ Reported, WriteFailed }!void {
    const name_utf8_len = std.unicode.calcWtf8Len(name_w);
    if (name_utf8_len > 255) return reportError(
        writer,
        "script name is {} bytes, too long (max 255)",
        .{name_utf8_len},
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

    var name_buf: [255]u8 = undefined;
    std.debug.assert(name_utf8_len == std.unicode.wtf16LeToWtf8(&name_buf, name_w));
    const name = name_buf[0..name_utf8_len];
    {
        var maybe_node = global.scripts.first;
        while (maybe_node) |list_node| : (maybe_node = list_node.next) {
            const script: *Script = @fieldParentPtr("list_node", list_node);
            if (std.mem.eql(u8, script.name(), name)) return reportError(
                writer,
                "script '{s}' is already running (requested by pid {})",
                .{ name, script.client.pid },
            );
        }
    }

    const run: Run = blk: {
        if (name[0] == '@') break :blk .{ .builtin = try parseBuiltin(writer, name, args) };

        if (args.next() catch return reportError(
            writer,
            "malformed run-script arguments",
            .{},
        )) |_| return reportError(
            writer,
            "script '{s}' was given arguments but scripts do not take arguments yet",
            .{name},
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
        const text = file.readToEndAlloc(
            std.heap.page_allocator,
            std.math.maxInt(usize),
        ) catch |err| return reportError(
            writer,
            "read '{f}' failed with {t}",
            .{ fmtW(path), err },
        );
        break :blk .{ .script = .{ .text = text } };
    };

    const script = std.heap.page_allocator.create(Script) catch {
        switch (run) {
            .script => |have_text| std.heap.page_allocator.free(have_text.text),
            .builtin => {},
        }
        return reportError(
            writer,
            "out of memory creating script '{f}'",
            .{fmtW(name_w)},
        );
    };
    script.* = .{
        .list_node = .{},
        .client = .{ .pid = pid, .pipe = pipe },
        .name_len = @intCast(name_utf8_len),
        .name_buf = undefined,
        .running = run,
    };
    @memcpy(script.name_buf[0..name.len], name);
    global.scripts.append(&script.list_node);
}

const Script = struct {
    list_node: std.DoublyLinkedList.Node,
    client: Client,
    name_len: u8,
    name_buf: [255]u8,
    running: Run,

    pub fn name(script: *const Script) []const u8 {
        return script.name_buf[0..script.name_len];
    }

    pub fn delete(script: *Script) void {
        switch (script.running) {
            .script => |*have_text| have_text.deinitFreeText(),
            .builtin => {},
        }
        win32.closeHandle(script.client.pipe);
        global.scripts.remove(&script.list_node);
        script.* = undefined;
        std.heap.page_allocator.destroy(script);
    }

    pub fn reportToClient(script: *Script, comptime fmt: []const u8, args: anytype) void {
        var file: std.fs.File = .{ .handle = script.client.pipe };
        var buf: [512]u8 = undefined;
        var file_writer = file.writerStreaming(&buf);
        const write_failed = blk: {
            file_writer.interface.print(fmt ++ "\n", args) catch |e| switch (e) {
                error.WriteFailed => break :blk true,
            };
            file_writer.interface.flush() catch |e| switch (e) {
                error.WriteFailed => break :blk true,
            };
            break :blk false;
        };
        if (write_failed) std.log.err(
            "write to client pipe failed with {t}",
            .{file_writer.err.?},
        );
    }

    pub fn nextYieldSleepMs(script: *const Script, now: std.time.Instant) u64 {
        const have_text = switch (script.running) {
            .script => |*t| t,
            .builtin => return std.math.maxInt(u64),
        };
        const vm_state = &(have_text.vm_state orelse return std.math.maxInt(u64));
        const yielded = &(vm_state.yielded orelse return std.math.maxInt(u64));
        return yielded.nextSleepMs(now);
    }
};

const Mod = struct {
    list_node: std.DoublyLinkedList.Node,
    name_len: u8,
    name_buf: [255]u8,

    stale: bool,
    state: union(enum) {
        initial,
        err_no_text: ErrorNoText,
        have_text: HaveText,
    } = .initial,

    const Yielded = struct {
        time: std.time.Instant,
        timeout_ms: u64,
        block_resume: Vm.BlockResume,
        pub fn isExpired(yielded: *const Yielded) bool {
            const since_ns = getNow().since(yielded.time);
            return @divTrunc(since_ns, std.time.ns_per_ms) >= yielded.timeout_ms;
        }
        pub fn nextSleepMs(yielded: *const Yielded, now: std.time.Instant) u64 {
            const since_ns = now.since(yielded.time);
            const since_ms = @divTrunc(since_ns, std.time.ns_per_ms);
            if (since_ms >= yielded.timeout_ms) return 0;
            return yielded.timeout_ms - since_ms;
        }
    };

    const HaveText = struct {
        text: []u8,
        vm_state: ?struct {
            instance: Vm,
            yielded: ?Yielded,
        } = null,
        pub fn deinitTakeText(have_text: *HaveText) []u8 {
            if (have_text.vm_state) |*vm_state| {
                vm_state.instance.deinit();
                vm_state.* = undefined;
                have_text.vm_state = null;
            }
            const text = have_text.text;
            have_text.* = undefined;
            return text;
        }
        pub fn deinitFreeText(have_text: *HaveText) void {
            const text = have_text.deinitTakeText();
            std.heap.page_allocator.free(text);
        }
    };

    fn create(name_slice: []const u8, name_len: u8) error{OutOfMemory}!*Mod {
        const mod = try std.heap.page_allocator.create(Mod);
        errdefer std.heap.page_allocator.destroy(mod);
        mod.* = .{
            .list_node = .{},
            .name_len = name_len,
            .name_buf = undefined,
            .stale = false,
        };
        @memcpy(mod.name_buf[0..name_len], name_slice);
        return mod;
    }

    pub fn delete(mod: *Mod) void {
        switch (mod.state) {
            .initial, .err_no_text => {},
            .have_text => |*state| {
                std.heap.page_allocator.free(state.text);
                state.* = undefined;
            },
        }
        global.mods.remove(&mod.list_node);
        mod.* = undefined;
        std.heap.page_allocator.destroy(mod);
    }

    pub fn nextYieldSleepMs(mod: *const Mod, now: std.time.Instant) u64 {
        const have_text = switch (mod.state) {
            .initial, .err_no_text => return std.math.maxInt(u64),
            .have_text => |h| h,
        };
        const vm_state = &(have_text.vm_state orelse return std.math.maxInt(u64));
        const yielded = &(vm_state.yielded orelse return std.math.maxInt(u64));
        return yielded.nextSleepMs(now);
    }

    const ErrorNoText = union(enum) {
        open_file: std.fs.File.OpenError,
        // read_file: (error{OutOfMemory} || std.fs.File.ReadError),
        read_file: anyerror,
        pub fn eql(self: ErrorNoText, other: ErrorNoText) bool {
            return switch (self) {
                .open_file => |self_e| switch (other) {
                    .open_file => |other_e| self_e == other_e,
                    else => false,
                },
                .read_file => |self_e| switch (other) {
                    .read_file => |other_e| self_e == other_e,
                    else => false,
                },
            };
        }
    };

    pub fn name(mod: *const Mod) []const u8 {
        return mod.name_buf[0..mod.name_len];
    }

    fn logNewErrorNoText(mod: *Mod, err: ErrorNoText) void {
        switch (err) {
            .open_file => |e| std.log.err("open mod file '{s}' failed with {t}", .{ mod.name(), e }),
            .read_file => |e| std.log.err("read mod file '{s}' failed with {t}", .{ mod.name(), e }),
        }
    }

    pub fn onErrorNoText(mod: *Mod, err: ErrorNoText) void {
        switch (mod.state) {
            .initial => {},
            .err_no_text => |current_error| if (current_error.eql(err)) return,
            .have_text => |*state| state.deinitFreeText(),
        }
        mod.logNewErrorNoText(err);
        mod.state = .{ .err_no_text = err };
    }

    pub fn updateText(mod: *Mod, new_text: []const u8) void {
        switch (mod.state) {
            .initial, .err_no_text => {},
            .have_text => |*state| {
                if (std.mem.eql(u8, state.text, new_text)) return;
                std.log.info(
                    "mod '{s}' text updated (size went from {} to {})",
                    .{ mod.name(), state.text.len, new_text.len },
                );
                // NOTE: we need to de-initialize the VM before we resize the text buffer
                const text = state.deinitTakeText();
                if (std.heap.page_allocator.resize(text, new_text.len)) {
                    std.log.debug("  resized text buffer in place", .{ state.text.len, new_text.len });
                    @memcpy(text.ptr[0..new_text.len], new_text);
                    state.* = .{ .text = text.ptr[0..new_text.len] };
                    return;
                }
                std.log.debug("  can't resize, freeing old text at 0x{x} of size {}", .{ @intFromPtr(text.ptr), text.len });
                std.heap.page_allocator.free(text);
                mod.state = .initial;
            },
        }
        const copy = std.heap.page_allocator.dupe(u8, new_text) catch |e| switch (e) {
            error.OutOfMemory => {
                std.log.err("can't save mod source, out of memory", .{});
                mod.state = .{ .err_no_text = .{ .read_file = e } };
                return;
            },
        };
        std.log.info("mod '{s}' source loaded", .{mod.name()});
        mod.state = .{ .have_text = .{ .text = copy, .vm_state = null } };
    }
};

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

fn updateMods(
    mods_path: ModsPath,
    dotnet_funcs: *const dotnet.Funcs,
    scratch: std.mem.Allocator,
    out_tests_scheduled: *bool,
) ?UpdateModsError {
    std.debug.assert(out_tests_scheduled.* == false);

    {
        var maybe_mod = global.mods.first;
        while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
            const mod: *Mod = @fieldParentPtr("list_node", list_node);
            mod.stale = true;
        }
    }

    if (false) std.log.info("loading mods from '{f}'...", .{mods_path});
    var dir = mods_path.open(.{ .iterate = true }) catch |err| {
        // TODO: should we try seeing if the mutiny folder even exists
        return .{ .open_mods_dir_error = err };
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch |err| {
        std.log.err("iterate mod directory '{f}' failed with {s}", .{ mods_path, @errorName(err) });
        return .{ .iterate_mods_dir_error = err };
    }) |entry| {
        if (entry.kind != .file) continue;
        const mod_name_len: u8 = std.math.cast(u8, entry.name.len) orelse {
            std.log.err("mod name ({}) is too log (max is 255)", .{entry.name.len});
            continue;
        };

        const mod: *Mod = blk: {
            {
                var maybe_mod = global.mods.first;
                while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
                    const mod: *Mod = @fieldParentPtr("list_node", list_node);
                    if (std.mem.eql(u8, mod.name(), entry.name)) break :blk mod;
                }
            }

            const mod = Mod.create(entry.name, mod_name_len) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.err("can't load new mod '{s}' (out of memory)", .{entry.name});
                    continue;
                },
            };
            global.mods.append(&mod.list_node);
            break :blk mod;
        };
        mod.stale = false;

        {
            var file = dir.openFile(entry.name, .{}) catch |err| {
                mod.onErrorNoText(.{ .open_file = err });
                continue;
            };
            defer file.close();
            const new_text = file.readToEndAlloc(scratch, std.math.maxInt(usize)) catch |err| {
                mod.onErrorNoText(.{ .read_file = err });
                continue;
            };
            defer scratch.free(new_text);
            mod.updateText(new_text);
        }

        switch (mod.state) {
            .initial, .err_no_text => {},
            .have_text => |*h| runMod(dotnet_funcs, out_tests_scheduled, mod.name(), h, null),
        }
    }

    while (findStaleMod()) |mod| {
        std.log.info("deleting mod '{s}'", .{mod.name()});
        mod.delete();
    }
    return null;
}

fn serviceScripts(dotnet_funcs: *const dotnet.Funcs, out_tests_scheduled: *bool) u64 {
    var sleep_time_ms: u64 = std.math.maxInt(u64);
    var maybe_node = global.scripts.first;
    while (maybe_node) |list_node| {
        maybe_node = list_node.next;
        const script: *Script = @fieldParentPtr("list_node", list_node);
        var pipe_file: std.fs.File = .{ .handle = script.client.pipe };
        var pipe_buf: [4096]u8 = undefined;
        var pipe_writer = pipe_file.writerStreaming(&pipe_buf);
        const have_text = switch (script.running) {
            .builtin => |builtin_script| {
                runBuiltin(dotnet_funcs, builtin_script, &pipe_writer.interface) catch |err| switch (err) {
                    error.WriteFailed => std.log.err(
                        "write to client pipe failed with {t}",
                        .{pipe_writer.err.?},
                    ),
                };
                script.delete();
                continue;
            },
            .script => |*t| t,
        };
        runMod(
            dotnet_funcs,
            out_tests_scheduled,
            script.name(),
            have_text,
            &pipe_writer.interface,
        );

        const vm_state = &have_text.vm_state.?;
        if (vm_state.yielded == null) {
            switch (vm_state.instance.error_result) {
                .exit => {},
                .err => |err| script.reportToClient("error: {f}", .{err.fmt(have_text.text, dotnet_funcs)}),
            }
            script.delete();
        } else {
            sleep_time_ms = @min(sleep_time_ms, script.nextYieldSleepMs(getNow()));
        }
    }
    return sleep_time_ms;
}

fn runBuiltin(
    dotnet_funcs: *const dotnet.Funcs,
    builtin_script: Builtin,
    writer: *std.Io.Writer,
) error{WriteFailed}!void {
    switch (builtin_script) {
        .assemblies => try writeAssemblies(dotnet_funcs, writer, .names),
        .decomp => try writeDecomp(dotnet_funcs, writer),
    }
    try writer.flush();
}

const AssemblyFormat = enum { names, decomp };

fn writeDecomp(
    dotnet_funcs: *const dotnet.Funcs,
    writer: *std.Io.Writer,
) error{WriteFailed}!void {
    try writer.print("runtime\t{s}\n", .{@tagName(dotnet_funcs.kind)});

    var path_buf: [appdata.max_path:0]u16 = undefined;
    {
        const len = win32.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0) win32.panicWin32("GetModuleFileNameW(null)", win32.GetLastError());
        try writer.print("exe\t{f}\n", .{fmtW(path_buf[0..len])});
    }
    switch (dotnet_funcs.kind) {
        .mono => {},
        .il2cpp => {
            const module = win32.GetModuleHandleW(
                win32.L(dotnet.dll_name_il2cpp),
            ) orelse win32.panicWin32("GetModuleHandleW", win32.GetLastError());
            const len = win32.GetModuleFileNameW(module, &path_buf, path_buf.len);
            if (len == 0) win32.panicWin32("GetModuleFileNameW", win32.GetLastError());
            try writer.print("module\t{s}\t{f}\n", .{
                dotnet.dll_name_il2cpp,
                fmtW(path_buf[0..len]),
            });
        },
    }
    try writeAssemblies(dotnet_funcs, writer, .decomp);
}

const WriteAssemblies = struct {
    dotnet_funcs: *const dotnet.Funcs,
    writer: *std.Io.Writer,
    format: AssemblyFormat,
    index: usize = 0,
    write_failed: bool = false,
};

fn writeAssembliesMono(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *const dotnet.Assembly = @ptrCast(assembly_opaque);
    const ctx: *WriteAssemblies = @ptrCast(@alignCast(user_data));
    defer ctx.index += 1;
    const mono = &ctx.dotnet_funcs.kind.mono;
    const assembly_name = mono.assembly_get_name(assembly) orelse {
        std.log.err("  assembly[{}] mono_assembly_get_name failed", .{ctx.index});
        return;
    };
    const str = mono.assembly_name_get_name(assembly_name) orelse {
        std.log.err(
            "  assembly[{}] mono_assembly_name_get_name failed (assembly_ptr=0x{x}, name_ptr=0x{x})",
            .{ ctx.index, @intFromPtr(assembly), @intFromPtr(assembly_name) },
        );
        return;
    };
    const name = std.mem.span(str);
    const result = switch (ctx.format) {
        .names => ctx.writer.print("{s}\n", .{name}),
        .decomp => blk: {
            const image = ctx.dotnet_funcs.assembly_get_image(assembly) orelse {
                std.log.err("  assembly[{}] mono_assembly_get_image failed", .{ctx.index});
                return;
            };
            const filename = mono.image_get_filename(image) orelse {
                std.log.err("  assembly[{}] mono_image_get_filename failed", .{ctx.index});
                return;
            };
            break :blk ctx.writer.print("assembly\t{s}\t{s}\n", .{ name, std.mem.span(filename) });
        },
    };
    result catch |err| switch (err) {
        error.WriteFailed => ctx.write_failed = true,
    };
}

fn writeAssemblies(
    dotnet_funcs: *const dotnet.Funcs,
    writer: *std.Io.Writer,
    format: AssemblyFormat,
) error{WriteFailed}!void {
    switch (dotnet_funcs.kind) {
        .mono => |*mono| {
            var context: WriteAssemblies = .{
                .dotnet_funcs = dotnet_funcs,
                .writer = writer,
                .format = format,
            };
            mono.assembly_foreach(&writeAssembliesMono, &context);
            if (context.write_failed) return error.WriteFailed;
        },
        .il2cpp => |*il2cpp| {
            var assembly_count: usize = undefined;
            const assemblies = il2cpp.domain_get_assemblies(
                dotnet_funcs.domain_get().?,
                &assembly_count,
            );
            for (0..assembly_count) |i| {
                const image = il2cpp.assembly_get_image(assemblies[i]);
                const image_name = std.mem.span(il2cpp.image_get_name(image));
                if (std.mem.eql(u8, image_name, "__Generated")) continue;
                if (!std.mem.endsWith(u8, image_name, ".dll")) std.debug.panic(
                    "expected all image names to end with '.dll' but got '{s}'",
                    .{image_name},
                );
                const name = image_name[0 .. image_name.len - ".dll".len];
                switch (format) {
                    .names => try writer.print("{s}\n", .{name}),
                    .decomp => try writer.print("assembly\t{s}\n", .{name}),
                }
            }
        },
    }
}

fn runMod(
    dotnet_funcs: *const dotnet.Funcs,
    out_tests_scheduled: *bool,
    mod_name: []const u8,
    have_text: *Mod.HaveText,
    out: ?*std.Io.Writer,
) void {
    const Eval = struct {
        vm: *Vm,
        block_resume: Vm.BlockResume,
    };

    const maybe_eval: ?Eval = blk: {
        if (have_text.vm_state) |*vm_state| {
            if (vm_state.yielded) |*yielded| {
                if (yielded.isExpired()) {
                    std.log.debug("{s}: yield expired!", .{mod_name});
                    const block_resume = yielded.block_resume;
                    vm_state.yielded = null;
                    break :blk .{
                        .vm = &vm_state.instance,
                        .block_resume = block_resume,
                    };
                }
            }
            break :blk null;
        } else {
            have_text.vm_state = .{
                .yielded = null,
                .instance = .{
                    .dotnet_funcs = dotnet_funcs,
                    .text = have_text.text,
                    .mem = .{ .allocator = std.heap.page_allocator },
                },
            };
            break :blk .{
                .vm = &have_text.vm_state.?.instance,
                .block_resume = .{},
            };
        }
    };
    if (maybe_eval) |eval| {
        eval.vm.out = out;
        defer eval.vm.out = null;
        if (eval.vm.evalRoot(eval.block_resume)) |yield| {
            // TODO: call vm.verifyStack?
            out_tests_scheduled.* = out_tests_scheduled.* or eval.vm.tests_scheduled;
            eval.vm.tests_scheduled = false;
            have_text.vm_state.?.yielded = .{
                .time = getNow(),
                .timeout_ms = if (yield.millis < 0) 0 else @intCast(yield.millis),
                .block_resume = yield.block_resume,
            };
        } else |_| switch (eval.vm.error_result) {
            .exit => {
                out_tests_scheduled.* = out_tests_scheduled.* or eval.vm.tests_scheduled;
                std.log.info("{s} has exited", .{mod_name});
                eval.vm.reset();
                have_text.vm_state.?.yielded = null;
            },
            .err => |err| {
                std.log.err("{s}:{f}", .{ mod_name, err.fmt(have_text.text, dotnet_funcs) });
            },
        }
    }
}

fn getNow() std.time.Instant {
    return std.time.Instant.now() catch unreachable;
}

fn findStaleMod() ?*Mod {
    var maybe_mod = global.mods.first;
    while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
        const mod: *Mod = @fieldParentPtr("list_node", list_node);
        if (mod.stale) return mod;
    }
    return null;
}

// // Export a function that the C# managed code can call
// // This allows us to bridge between native and managed
// export fn NativeLog(message: [*:0]const u8) callconv(.c) void {
//     const msg = std.mem.span(message);
//     std.log.info("{s}", .{msg});
// }

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

// fn getBasename(path: []const u16) []const u16 {
//     for (1..path.len) |i| {
//         if (path[path.len - i] == '\\')
//             return path[path.len - i + 1 ..];
//     }
//     return path;
// }
// fn getDirname(path: []const u16) ?[]const u16 {
//     for (1..path.len) |i| {
//         if (path[path.len - i] == '\\')
//             return path[0 .. path.len - i];
//     }
//     return null;
// }

fn fmtMsgbox(
    style: win32.MESSAGEBOX_STYLE,
    title: [*:0]const u8,
    comptime fmt: [:0]const u8,
    args: anytype,
) win32.MESSAGEBOX_RESULT {
    if (style.ICONHAND == 1) {
        std.log.err("msgbox(error) " ++ fmt, args);
    } else {
        std.log.info("msgbox: " ++ fmt, args);
    }
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const msg = std.fmt.allocPrintSentinel(arena, fmt, args, 0) catch |err| switch (err) {
        error.OutOfMemory => fmt,
    };
    //defer global.arena.free(msg);
    return win32.MessageBoxA(null, msg, title, style);
}

fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
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
            const script_bytes = @as([*]const u8, @ptrCast(copy_data.lpData.?))[0..copy_data.cbData];
            const request: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, script_bytes));
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
        mutinyipc.wm_heartbeat => return mutinyipc.heartbeat_result,
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const fmtW = std.unicode.fmtUtf16Le;

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const appdata = @import("appdata.zig");
const Mutex = @import("Mutex.zig");
const mutinyipc = @import("mutinyipc.zig");
const Vm = @import("Vm.zig");
const logfile = @import("logfile.zig");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const UnityVersion = @import("UnityVersion.zig");
