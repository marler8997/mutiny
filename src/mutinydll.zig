const global = struct {
    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_dumping: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };

    var mods: std.DoublyLinkedList = .{};

    var write_log_mutex: Mutex = .{};

    var get_log_file_mutex: Mutex = .{};
    var log_file_cached: ?std.fs.File = null;
    pub fn getLogFile(open_error: *?win32.WIN32_ERROR) std.fs.File {
        std.debug.assert(open_error.* == null);
        get_log_file_mutex.lock();
        defer get_log_file_mutex.unlock();
        if (log_file_cached == null) {
            log_file_cached = blk: {
                if (builtin.os.tag == .windows) {
                    const handle = win32.CreateFileW(
                        win32.L("C:\\temp\\mutiny.log"),
                        .{ .FILE_APPEND_DATA = 1 }, // all writes append to end of file
                        .{ .READ = 1 },
                        null,
                        .CREATE_ALWAYS, // always create and truncate the file
                        .{ .FILE_ATTRIBUTE_NORMAL = 1 },
                        null,
                    );
                    if (handle != win32.INVALID_HANDLE_VALUE) break :blk .{ .handle = handle };
                    open_error.* = win32.GetLastError();
                } else @compileError("todo");
                break :blk std.fs.File.stderr();
            };
        }
        return log_file_cached.?;
    }
};

const OpenFileError = switch (builtin.os.tag) {
    .windows => win32.WIN32_ERROR,
    else => std.fs.File.OpenError,
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
        var maybe_open_error: ?OpenFileError = null;
        const log_file = global.getLogFile(&maybe_open_error);
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
    _ = hinst;
    _ = reserved;
    switch (reason) {
        win32.DLL_PROCESS_ATTACH => {
            // !!! WARNING !!! do not log here...logging uses APIs that we probably
            // aren't supposed to call at this phase.
            if (false) win32.OutputDebugStringW(win32.L("mutiny: proces attach\n"));

            // NOTE: the default thread stack size when specyfing 0 is too small when
            //       injecting into .NET asemblies, so, let' just ask for a reasonable 2MB
            //       no matter what.
            const thread_stack_size = 2 * 1024 * 1024;
            const thread = win32.CreateThread(null, thread_stack_size, initThreadEntry, null, .{}, null) orelse {
                win32.OutputDebugStringW(win32.L("mutiny: CreateThread failed"));
                // TODO: how can we log the error code?
                return 1; // fail
            };
            win32.closeHandle(thread);
        },
        win32.DLL_THREAD_ATTACH => {},
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

fn initThreadEntry(context: ?*anyopaque) callconv(.winapi) u32 {
    _ = context;
    std.log.info("Init Thread running!", .{});

    // if (win32.AddVectoredExceptionHandler(1, on_vectored_exception)) |_| {
    //     std.log.info("AddVectoredExceptionHandler success", .{});
    // } else {
    //     std.log.err("AddVectoredExceptionHandler failed, error={f}", .{win32.GetLastError()});
    // }

    const mono_dll_name = "mono-2.0-bdwgc.dll";
    const mono_mod = blk: {
        var attempt: u32 = 0;
        while (true) {
            attempt += 1;
            if (win32.GetModuleHandleW(win32.L(mono_dll_name))) |mono_mod|
                break :blk mono_mod;
            switch (win32.GetLastError()) {
                .ERROR_MOD_NOT_FOUND => {
                    std.log.info("{s}: not found yet...", .{mono_dll_name});
                },
                else => |e| std.debug.panic("GetModule '{s}' failed, error={f}", .{ mono_dll_name, e }),
            }
            const max_attempts = 30;
            if (attempt >= max_attempts) {
                _ = fmtMsgbox(
                    .{},
                    "Mutiny Fatal Error",
                    "failed to load the mono DLL after {} attempts",
                    .{max_attempts},
                );
                return 0xffffffff;
            }
            const sleep_ms = 1;
            if (false) std.log.info("sleeping for {} ms", .{sleep_ms});
            win32.Sleep(sleep_ms);
        }
    };
    std.log.info("{s}: 0x{x}", .{ mono_dll_name, @intFromPtr(mono_mod) });

    const mono_funcs: mono.Funcs = blk: {
        var missing_proc: [:0]const u8 = undefined;
        break :blk mono.Funcs.init(&missing_proc, mono_mod) catch {
            _ = fmtMsgbox(
                .{},
                "Mutiny Fatal Error",
                "the mono dll '{s}' is missing proc '{s}'",
                .{ mono_dll_name, missing_proc },
            );
            return 0xffffffff;
        };
    };

    const root_domain = blk: {
        var attempt: u32 = 0;
        while (true) {
            attempt += 1;
            if (mono_funcs.get_root_domain()) |domain| {
                std.log.info("Mono root domain found: 0x{x}", .{@intFromPtr(domain)});
                break :blk domain;
            }
            std.log.info("mono_get_root_domain returned NULL (attempt {})", .{attempt});
            const max_attempts = 30;
            if (attempt >= max_attempts) {
                std.log.err("unable to get mono root domain after {} attempts", .{max_attempts});
                return 0xffffffff;
            }
            std.Thread.sleep(std.time.ns_per_s * 1);
        }
    };

    // if we go to fast the process will intermittently crash
    // TODO: find a better way to do this, might need to inspect mono source to find it
    std.log.info("waiting a second for main process to initialize mono...", .{});
    std.Thread.sleep(std.time.ns_per_s * 1);

    // sanity check, this should be null before we call thread_attach
    std.debug.assert(mono_funcs.domain_get() == null);

    // std.log.info("Attaching thread to Mono domain...", .{});
    const thread = mono_funcs.thread_attach(root_domain) orelse {
        std.log.err("mono_thread_attach failed!", .{});
        return 0xffffffff;
    };
    std.log.info("thread attach success 0x{x}", .{@intFromPtr(thread)});

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(mono_funcs.domain_get() == root_domain);

    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    while (true) {
        const update_result = updateMods(
            &mono_funcs,
            scratch.allocator(),
        );
        if (!scratch.reset(.retain_capacity)) {
            std.log.warn("reset scratch allocator failed?", .{});
        }

        if (update_result.tests_scheduled) {
            std.log.info("@ScheduleTests requested! running...", .{});
            Vm.runTests(&mono_funcs) catch |err| {
                std.log.err("tests failed with {s}:", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                } else {
                    std.log.err("    no error trace", .{});
                }
            };
        }

        // var sleep_time_ms: u64 = 5000;
        var sleep_time_ms: u64 = 1000;
        const now = getNow();
        {
            var maybe_mod = global.mods.first;
            while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
                const mod: *Mod = @fieldParentPtr("list_node", list_node);
                sleep_time_ms = @min(sleep_time_ms, mod.nextYieldSleepMs(now));
            }
        }
        std.Thread.sleep(sleep_time_ms);
    }

    return 0;
}

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
                if (std.heap.page_allocator.resize(state.text, new_text.len)) {
                    std.log.debug("  resized text buffer in place", .{ state.text.len, new_text.len });
                    const text = state.deinitTakeText();
                    @memcpy(text.ptr[0..new_text.len], new_text);
                    state.* = .{ .text = text.ptr[0..new_text.len] };
                    return;
                }
                std.log.debug("  can't resize", .{});
                state.deinitFreeText();
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

const UpdateModsResult = struct {
    tests_scheduled: bool,
};

fn updateMods(
    mono_funcs: *const mono.Funcs,
    scratch: std.mem.Allocator,
) UpdateModsResult {
    var result: UpdateModsResult = .{ .tests_scheduled = false };

    {
        var maybe_mod = global.mods.first;
        while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
            const mod: *Mod = @fieldParentPtr("list_node", list_node);
            mod.stale = true;
        }
    }

    const mod_path = "C:\\temp\\mutinymods";
    if (false) std.log.info("loading mods from '{s}'...", .{mod_path});
    var dir = std.fs.cwd().openDir(mod_path, .{ .iterate = true }) catch |err| {
        std.log.err("open mod directory '{s}' failed with {s}", .{ mod_path, @errorName(err) });
        return result;
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |err| {
        std.log.err("iterate mod directory '{s}' failed with {s}", .{ mod_path, @errorName(err) });
        return result;
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
            .have_text => |*h| runMod(mono_funcs, &result, mod.name(), h),
        }
    }

    while (findStaleMod()) |mod| {
        std.log.info("deleting mod '{s}'", .{mod.name()});
        mod.delete();
    }
    return result;
}

fn runMod(
    mono_funcs: *const mono.Funcs,
    update_mods_result: *UpdateModsResult,
    mod_name: []const u8,
    have_text: *Mod.HaveText,
) void {
    const Eval = struct {
        vm: *Vm,
        block_resume: Vm.BlockResume,
    };

    const maybe_eval: ?Eval = blk: {
        if (have_text.vm_state) |*vm_state| {
            if (vm_state.yielded) |*yielded| {
                if (yielded.isExpired()) {
                    std.log.info("{s}: yield expired!", .{mod_name});
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
                    .mono_funcs = mono_funcs,
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
        if (eval.vm.evalRoot(eval.block_resume)) |yield| {
            // TODO: call vm.verifyStack?
            update_mods_result.tests_scheduled = update_mods_result.tests_scheduled or eval.vm.tests_scheduled;
            eval.vm.tests_scheduled = false;
            have_text.vm_state.?.yielded = .{
                .time = getNow(),
                .timeout_ms = if (yield.millis < 0) 0 else @intCast(yield.millis),
                .block_resume = yield.block_resume,
            };
        } else |_| switch (eval.vm.error_result) {
            .exit => {
                std.log.info("{s} has exited", .{mod_name});
                eval.vm.reset();
                have_text.vm_state.?.yielded = null;
            },
            .err => |err| {
                std.log.err("{s}:{f}", .{ mod_name, err.fmt(have_text.text) });
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
    const level_txt = comptime message_level.asText();
    const scope_suffix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";
    const level_scope = level_txt ++ scope_suffix;

    var maybe_open_error: ?OpenFileError = null;
    const log_file = global.getLogFile(&maybe_open_error);
    var buffer: [1024]u8 = undefined;
    var file_writer = log_file.writer(&buffer);

    global.write_log_mutex.lock();
    defer global.write_log_mutex.unlock();
    writeFlushLog(level_scope ++ "|" ++ format, args, &file_writer.interface, maybe_open_error) catch std.debug.panic(
        "write log failed with {s}",
        .{@errorName(file_writer.err orelse error.Unexpected)},
    );
}

fn writeLogPrefix(writer: *std.Io.Writer) error{WriteFailed}!void {
    // const name: []const u16 = blk: {
    //     const p = getImagePathName() orelse break :blk win32.L("?");
    //     break :blk getBasename(p);
    // };
    var time: win32.SYSTEMTIME = undefined;
    win32.GetSystemTime(&time);
    try writer.print(
        "{:0>2}:{:0>2}:{:0>2}.{:0>3}|{}|{}|",
        .{ time.wHour, time.wMinute, time.wSecond, time.wMilliseconds, win32.GetCurrentProcessId(), win32.GetCurrentThreadId() },
    );
}
fn writeFlushLog(
    comptime format: []const u8,
    args: anytype,
    writer: *std.Io.Writer,
    maybe_open_error: ?OpenFileError,
) error{WriteFailed}!void {
    if (maybe_open_error) |open_error| {
        try writeLogPrefix(writer);
        if (builtin.os.tag == .windows)
            try writer.print("open log file failed, error={f}\n", .{open_error})
        else
            try writer.print("open log file failed with {s}\n", .{@errorName(open_error)});
    }
    try writeLogPrefix(writer);
    try writer.print(format ++ "\n", args);
    try writer.flush();
}

// fn getImagePathName() ?[]const u16 {
//     const str = &std.os.windows.peb().ProcessParameters.ImagePathName;
//     if (str.Buffer) |buffer|
//         return buffer[0..@divTrunc(str.Length, 2)];
//     return null;
// }
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
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const msg = std.fmt.allocPrintSentinel(arena, fmt, args, 0) catch |err| switch (err) {
        error.OutOfMemory => fmt,
    };
    //defer global.arena.free(msg);
    return win32.MessageBoxA(null, msg, title, style);
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const Mutex = @import("Mutex.zig");
const Vm = @import("Vm.zig");
const mono = @import("mono.zig");
