const global = struct {
    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_dumping: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };

    var mods: std.DoublyLinkedList = .{};

    const localappdata = struct {
        var mutex: Mutex = .{};
        var initialized: bool = false;
        var cached: ?[:0]const u16 = null;
    };
    pub fn getLocalappdata() ?[]const u16 {
        // localappdata.mutex.lock();
        // defer localappdata.mutex.unlock();
        // if (!localappdata.initialized) {
        //     localappdata.cached = std.process.getenvW(win32.L("localappdata"));
        //     localappdata.initialized = true;
        // }
        // return localappdata.cached;
        return null;
    }
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
        // if (error_return_trace) |trace| {
        //     dumpStackTrace(trace.*);
        // } else {
        //     std.log.err("    no error trace", .{});
        // }
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

// fn dumpStackTrace() void {
//     // const stderr = lockStderrWriter(&.{});
//     // defer unlockStderrWriter();
//     if (builtin.strip_debug_info) {
//         stderr.writeAll("Unable to dump stack trace: debug info stripped\n") catch return;
//         return;
//     }
//     const debug_info = getSelfDebugInfo() catch |err| {
//         stderr.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
//         return;
//     };
//     writeStackTrace(stack_trace, stderr, debug_info, io.tty.detectConfig(.stderr())) catch |err| {
//         stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
//         return;
//     };
// }

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

            // NOTE: the default thread stack size when specyfing 0 is too small when
            //       injecting into .NET asemblies, so, let' just ask for a reasonable 2MB
            //       no matter what.
            const thread_stack_size = 2 * 1024 * 1024;
            const thread = win32.CreateThread(null, thread_stack_size, initThreadEntry, null, .{}, null) orelse {
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
    var stdout = std.fs.File.stdout().writer(&.{});
    stdout.interface.writeAll("stdout is working\n") catch {
        std.log.err(
            "write to stdout failed with {t}",
            .{stdout.err orelse error.Unexpected},
        );
    };
    var stderr = std.fs.File.stderr().writer(&.{});
    stderr.interface.writeAll("stderr is working\n") catch {
        std.log.err(
            "write to stderr failed with {t}",
            .{stderr.err orelse error.Unexpected},
        );
    };

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
            std.Thread.sleep(std.time.ns_per_s * 1);
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

    // sanity check, this should be null before we call thread_attach
    std.debug.assert(mono_funcs.domain_get() == null);

    // std.log.info("Attaching thread to Mono domain...", .{});
    const thread = mono_funcs.thread_attach(root_domain) orelse {
        std.log.err("mono_thread_attach failed!", .{});
        return 0xffffffff;
    };
    std.log.info("thread attach succes 0x{x}", .{@intFromPtr(thread)});

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(mono_funcs.domain_get() == root_domain);

    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    while (true) {
        var tests_scheduled: bool = false;
        updateMods(&mono_funcs, scratch.allocator(), &tests_scheduled);
        if (!scratch.reset(.retain_capacity)) {
            std.log.warn("reset scratch allocator failed?", .{});
        }

        if (tests_scheduled) {
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
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // std.Thread.sleep(std.time.ns_per_s * 5);
        std.Thread.sleep(std.time.ns_per_s * 1);
    }

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

    const HaveText = struct {
        text: []u8,
        processed: bool,
        pub fn deinitTakeText(have_text: *HaveText) []u8 {
            const text = have_text.text;
            have_text.* = undefined;
            return text;
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
            .have_text => |state| {
                std.heap.page_allocator.free(state.text);
                mod.state = undefined;
            },
        }
        mod.logNewErrorNoText(err);
        mod.state = .{ .err_no_text = err };
    }

    pub fn updateText(mod: *Mod, new_text: []const u8) void {
        switch (mod.state) {
            .initial, .err_no_text => {},
            .have_text => |*state| {
                if (std.mem.eql(u8, state.text, new_text)) return;
                std.log.info("mod '{s}' text updated", .{mod.name()});
                if (std.heap.page_allocator.resize(state.text, new_text.len)) {
                    std.log.debug("  resized!", .{});
                    @memcpy(state.text.ptr[0..new_text.len], new_text);
                    const text = state.deinitTakeText();
                    mod.state = .{ .have_text = .{
                        .text = text.ptr[0..new_text.len],
                        .processed = false,
                    } };
                    return;
                }
                std.log.debug("  can't resize", .{});
                std.heap.page_allocator.free(state.text);
                mod.state = undefined;
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
        mod.state = .{ .have_text = .{ .text = copy, .processed = false } };
    }
};

fn updateMods(
    mono_funcs: *const mono.Funcs,
    scratch: std.mem.Allocator,
    run_tests_ref: *bool,
) void {
    {
        var maybe_mod = global.mods.first;
        while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
            const mod: *Mod = @fieldParentPtr("list_node", list_node);
            mod.stale = true;
        }
    }

    const mod_path = "C:\\temp\\marlermods";
    if (false) std.log.info("loading mods from '{s}'...", .{mod_path});
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
            .have_text => |*state| if (!state.processed) {
                var vm: Vm = .{
                    .mono_funcs = mono_funcs,
                    .text = state.text,
                    .err = undefined,
                    .mem = .{ .allocator = scratch },
                    .symbols = .{},
                };
                defer vm.deinit();
                vm.evalRoot() catch {
                    std.log.err("{s}:{f}", .{ mod.name(), vm.err.fmt(state.text) });
                };
                run_tests_ref.* = run_tests_ref.* or vm.tests_scheduled;
                // TODO: call vm.verifyStack?
                state.processed = true;
            },
        }
    }

    while (findStaleMod()) |mod| {
        std.log.info("deleting mod '{s}'", .{mod.name()});
        mod.delete();
    }
}

fn findStaleMod() ?*Mod {
    var maybe_mod = global.mods.first;
    while (maybe_mod) |list_node| : (maybe_mod = list_node.next) {
        const mod: *Mod = @fieldParentPtr("list_node", list_node);
        if (mod.stale) return mod;
    }
    return null;
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

    const maybe_localappdata = global.getLocalappdata();
    // var logfile_size: ?u64 = null;

    var buffer: [400]u8 = undefined;
    const writer: *std.Io.Writer = blk: {
        const localappdata = maybe_localappdata orelse break :blk std.debug.lockStderrWriter(
            &buffer,
        );
        _ = localappdata;
        // const log_file = openLog(localappdata);
        // defer log_file.close();
        @panic("todo");
        // const log_file = openLog(localappdata) orelse {
        //     @p
        // };
    };
    defer if (maybe_localappdata == null) std.debug.unlockStderrWriter();

    // const name: []const u16 = blk: {
    //     const p = getImagePathName() orelse break :blk win32.L("?");
    //     break :blk getBasename(p);
    // };

    {
        var time: win32.SYSTEMTIME = undefined;
        win32.GetSystemTime(&time);
        writer.print(
            "mod: {:0>2}:{:0>2}:{:0>2}.{:0>3}|{}|" ++ level_txt ++ scope_suffix ++ "|",
            .{ time.wHour, time.wMinute, time.wSecond, time.wMilliseconds, win32.GetCurrentThreadId() },
        ) catch |err| std.debug.panic("print log prefix failed with {s}", .{@errorName(err)});
    }
    writer.print(format ++ "\n", args) catch |err| std.debug.panic("print log failed with {s}", .{@errorName(err)});
    writer.flush() catch |err| std.debug.panic("flush log file failed with {s}", .{@errorName(err)});
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

// fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
//     //if (global.log_file) |f| {
//     //    f.writer().writeAll("fatal: ") catch { };
//     //    f.writer().print(fmt, args) catch { };
//     //}
//     _ = msgbox(.{}, "MarlerMod.dll: Fatal Error", fmt, args);
//     win32.ExitProcess(0xff);
// }

const std = @import("std");
const win32 = @import("win32").everything;
const Mutex = @import("Mutex.zig");
const Vm = @import("Vm.zig");
const mono = @import("mono.zig");
