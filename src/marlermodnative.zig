const global = struct {
    var mutex: Mutex = .{};
    var localappdata_resolved: bool = false;
    var localappdata: ?[]const u16 = null;
    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };

    var mods: std.DoublyLinkedList = .{};
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
                std.log.err("unable to load mono dll after {} attempts", .{max_attempts});
                return 0xffffffff;
            }
            std.Thread.sleep(std.time.ns_per_s * 1);
        }
    };
    std.log.info("{s}: 0x{x}", .{ mono_dll_name, @intFromPtr(mono_mod) });

    const mono_funcs: mono.Funcs = blk: {
        var missing_proc: [:0]const u8 = undefined;
        break :blk mono.Funcs.init(&missing_proc, mono_mod) catch errExit(
            "the mono dll '{s}' is missing proc '{s}'",
            .{ mono_dll_name, missing_proc },
        );
    };

    const domain = blk: {
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

    // std.log.info("Attaching thread to Mono domain...", .{});
    const thread = mono_funcs.thread_attach(domain) orelse {
        std.log.err("mono_thread_attach failed!", .{});
        return 0xffffffff;
    };
    std.log.info("thread attach succes 0x{x}", .{@intFromPtr(thread)});

    // if (true) @panic("todo");
    // // Now initialize managed runtime
    // initializeManagedRuntime(mono_mod) catch |err| {
    //     std.log.err("Failed to initialize managed runtime: {}", .{err});
    //     return 0xffffffff;
    // };

    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    while (true) {
        updateMods(&mono_funcs, domain, scratch.allocator());
        if (!scratch.reset(.retain_capacity)) {
            std.log.warn("reset scratch allocator failed?", .{});
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
    mono_domain: *const mono.Domain,
    scratch: std.mem.Allocator,
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
                    .mono_domain = mono_domain,
                    .text = state.text,
                    .err = undefined,
                    .mem = .{ .allocator = scratch },
                    .symbols = .{},
                };
                defer vm.deinit();
                vm.evalRoot() catch {
                    std.log.err("{s}:{f}", .{ mod.name(), vm.err.fmt(state.text) });
                };
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

// fn initializeManagedRuntime(mono_mod: win32.HINSTANCE) error{MissingProc}!void {
//     std.log.info("initializing managed runtime...", .{});
//     _ = mono_mod;

//     // const mono_thread_attach = win32.GetProcAddress(mono_mod, "mono_thread_attach") orelse return error.MissingFunction;
//     // const mono_domain_assembly_open = win32.GetProcAddress(mono_mod, "mono_domain_assembly_open") orelse return error.MissingFunction;
//     // const mono_assembly_get_image = win32.GetProcAddress(mono_mod, "mono_assembly_get_image") orelse return error.MissingFunction;
//     // const mono_class_from_name = win32.GetProcAddress(mono_mod, "mono_class_from_name") orelse return error.MissingFunction;
//     // const mono_class_get_method_from_name = win32.GetProcAddress(mono_mod, "mono_class_get_method_from_name") orelse return error.MissingFunction;
//     // const mono_runtime_invoke = win32.GetProcAddress(mono_mod, "mono_runtime_invoke") orelse return error.MissingFunction;

//     // // Cast to proper function types
//     // const thread_attach: *const fn (?*mono.Domain) callconv(.c) ?*MonoThread = @ptrCast(mono_thread_attach);
//     // const domain_assembly_open: *const fn (?*mono.Domain, [*:0]const u8) callconv(.c) ?*MonoAssembly = @ptrCast(mono_domain_assembly_open);
//     // const assembly_get_image: *const fn (?*MonoAssembly) callconv(.c) ?*MonoImage = @ptrCast(mono_assembly_get_image);
//     // const class_from_name: *const fn (?*MonoImage, [*:0]const u8, [*:0]const u8) callconv(.c) ?*MonoClass = @ptrCast(mono_class_from_name);
//     // const class_get_method_from_name: *const fn (?*MonoClass, [*:0]const u8, c_int) callconv(.c) ?*MonoMethod = @ptrCast(mono_class_get_method_from_name);
//     // const runtime_invoke: *const fn (?*MonoMethod, ?*MonoObject, ?*?*anyopaque, ?*?*MonoObject) callconv(.c) ?*MonoObject = @ptrCast(mono_runtime_invoke);

//     // Get root domain and attach thread
//     // const domain = mono_get_root_domain() orelse errExit(
//     //     "mono_get_root_domain returned NULL",
//     //     .{},
//     // );
//     // std.log.info("Mono root domain: 0x{x}", .{@intFromPtr(domain)});

//     // const thread = thread_attach(domain) orelse return error.ThreadAttachFailed;
//     // std.log.info("Thread attached: 0x{x}", .{@intFromPtr(thread)});

//     // // Load managed assembly
//     // const assembly_path = "C:\\temp\\MarlerModManaged.dll";
//     // std.log.info("Loading managed assembly: {s}", .{assembly_path});
//     // const assembly = domain_assembly_open(domain, assembly_path) orelse return error.AssemblyLoadFailed;

//     // const image = assembly_get_image(assembly) orelse return error.GetImageFailed;

//     // // Find class: MarlerMod.ModLoader
//     // const namespace = "MarlerMod";
//     // const class_name = "ModLoader";
//     // std.log.info("Finding class: {s}.{s}", .{ namespace, class_name });
//     // const class = class_from_name(image, namespace, class_name) orelse return error.ClassNotFound;

//     // // Find method: Initialize
//     // const method_name = "Initialize";
//     // std.log.info("Finding method: {s}", .{method_name});
//     // const method = class_get_method_from_name(class, method_name, 0) orelse return error.MethodNotFound;

//     // // Invoke the method
//     // std.log.info("Invoking {s}.{s}.{s}()", .{ namespace, class_name, method_name });
//     // var exception: ?*MonoObject = null;
//     // _ = runtime_invoke(method, null, null, &exception);

//     // if (exception != null) {
//     //     std.log.err("Exception occurred during method invocation", .{});
//     //     return error.InvocationException;
//     // }

//     // std.log.info("Managed code initialized successfully!", .{});
//     @panic("todo");
// }

const std = @import("std");
const win32 = @import("win32").everything;
const Mutex = @import("Mutex.zig");
const Vm = @import("Vm.zig");
const mono = @import("mono.zig");
