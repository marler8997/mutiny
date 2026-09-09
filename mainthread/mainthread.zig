pub const appdata = mutiny.appdata;
pub const logfile = mutiny.logfile;
pub const mutinyipc = mutiny.mutinyipc;

pub const BoundedArray = mutiny.BoundedArray;
pub const ModNameSlice = @import("ModNameSlice.zig");
pub const Mutex = mutiny.Mutex;
pub const Options = mutiny.Options;
pub const Pool = mutiny.Pool;

pub const ioThreadQueueModUpdate = mods.ioThreadQueueUpdate;
pub const ioThreadQueueModRemove = mods.ioThreadQueueRemove;
pub const ioThreadQueueScript = scripts.queue;

const global = struct {
    // state related to subclassing the main window
    const subclass = struct {
        var state: SubclassWindowState = .{ .initial = .{} };
        var wnd_msg: u32 = undefined;
        var hwnd: win32.HWND = undefined;
        const wndproc = struct {
            var mutex: std.Thread.Mutex = .{};
            var ptr: win32.WNDPROC = undefined;
        };
    };

    var bootstrap_state: std.atomic.Value(BootstrapState) = .init(.pending);
    var io_thread_id: std.atomic.Value(u32) = .init(0);
    var io_thread: ?win32.HANDLE = null;
    var runtime: RuntimeState = .{ .find_lib = .{} };
    var update_hook: UpdateHookState = .pending;
    var dotnet_funcs_store: dotnet.Funcs = undefined;
    // protects both run and onUpdate functions from simulatneously using shared state like
    // vm_arena due to recursive calls via message pump
    var vm_pass_active: bool = false;
    var vm_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
};

fn coalescedLog(
    comptime T: type,
    store: *T,
    new_value: T,
    comptime kind: enum { err, info },
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (std.meta.eql(new_value, store.*)) return;
    switch (kind) {
        .err => std.log.err(fmt, args),
        .info => std.log.info(fmt, args),
    }
    store.* = new_value;
    std.debug.assert(std.meta.eql(new_value, store.*));
}

const PostActionArgs = if (builtin.os.tag == .windows) struct {
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
} else struct {};

pub const AttachState = struct {
    stage: enum { subclass, bootstrap } = .subclass,
    last_post_result: PostResult = .posted,

    pub fn update(state: *AttachState) union(enum) { attached, failed, retry_ms: u32 } {
        stage: switch (state.stage) {
            .subclass => switch (subclassUpdate()) {
                .keep_calling => return .{ .retry_ms = subclass_retry_ms },
                .done => {
                    global.bootstrap_state.store(.pending, .monotonic);
                    state.stage = .bootstrap;
                    continue :stage state.stage;
                },
            },
            .bootstrap => switch (global.bootstrap_state.load(.monotonic)) {
                .pending => {
                    postBootstrap(&state.last_post_result);
                    return .{ .retry_ms = bootstrap_retry_ms };
                },
                .installed => return .attached,
                .failed => return .failed,
            },
        }
    }
};

const subclass_retry_ms = 200;
const bootstrap_retry_ms = 200;

const PostResult = union(enum) {
    posted,
    not_ready,
    post_error: PostError,
};

const BootstrapState = enum(u8) { pending, installed, failed };

pub fn ioThreadId() u32 {
    return global.io_thread_id.load(.monotonic);
}

fn ensureIoThread() bool {
    if (global.io_thread) |thread| switch (win32.WaitForSingleObject(thread, 0)) {
        @intFromEnum(win32.WAIT_TIMEOUT) => return true,
        @intFromEnum(win32.WAIT_OBJECT_0) => {
            std.log.err("the io thread died, starting another", .{});
            win32.closeHandle(thread);
            global.io_thread = null;
            global.io_thread_id.store(0, .monotonic);
        },
        else => |result| std.debug.panic(
            "WaitForSingleObject on the io thread returned {} (error={f})",
            .{ result, win32.GetLastError() },
        ),
    };
    return spawnIoThread();
}

fn spawnIoThread() bool {
    const name = switch (logfile.global.getName()) {
        .success => |s| s,
        .err => |err| {
            std.log.err("cannot start the io thread: {f}", .{err});
            return false;
        },
    };
    const localappdata = appdata.get() orelse {
        std.log.err("cannot start the io thread: no LOCALAPPDATA environment variable", .{});
        return false;
    };
    const thread = io.spawn(.{ .name = name, .localappdata = localappdata }) catch return false;
    global.io_thread_id.store(win32.GetThreadId(thread), .monotonic);
    global.io_thread = thread;
    return true;
}

fn postBootstrap(last_post_result: *PostResult) void {
    const new_result: PostResult = blk: switch (global.subclass.state) {
        .initial, .find_window, .subclass => .not_ready,
        .ready => {
            const target: Target = .{ .data = .{ .hwnd = global.subclass.hwnd, .msg = global.subclass.wnd_msg } };
            var err: PostError = undefined;
            target.post(.bootstrap, &err) catch break :blk .{ .post_error = err };
            break :blk .posted;
        },
    };

    // sanity check
    switch (new_result) {
        .posted, .not_ready => {},
        .post_error => |err| std.debug.assert(err.eql(err)),
    }

    switch (last_post_result.*) {
        .posted => switch (new_result) {
            .posted => {},
            .not_ready => std.log.info("can't post run to main thread, not ready yet", .{}),
            .post_error => |err| std.log.err("post run failed, error={f}", .{err}),
        },
        .not_ready => switch (new_result) {
            .posted => std.log.info("main thread now ready, run posted", .{}),
            .not_ready => {}, // already logged
            .post_error => |err| std.log.err("post run failed, error={f}", .{err}),
        },
        .post_error => |last_error| switch (new_result) {
            .posted => std.log.info("main thread post recovered from error", .{}),
            .not_ready => std.log.info("post error gone, but main thread still not ready", .{}),
            .post_error => |err| if (!last_error.eql(err)) std.log.err("new post run error: {f}", .{err}),
        },
    }
    last_post_result.* = new_result;
}

const PostAction = union(enum) {
    bootstrap,
    subclass_self_test,
    pub fn deserialize(args: PostActionArgs) ?PostAction {
        if (builtin.os.tag == .windows) {
            return switch (args.wparam) {
                1 => return .bootstrap,
                2 => return .subclass_self_test,
                else => null,
            };
        } else @panic("todo");
    }
    pub fn serialize(action: PostAction) PostActionArgs {
        if (builtin.os.tag == .windows) return switch (action) {
            .bootstrap => .{ .wparam = 1, .lparam = undefined },
            .subclass_self_test => .{ .wparam = 2, .lparam = undefined },
        } else @panic("todo");
    }
};

const PostError = struct {
    data: if (builtin.os.tag == .windows) win32.WIN32_ERROR else void,
    pub fn eql(err: PostError, other: PostError) bool {
        if (builtin.os.tag == .windows) {
            return err.data == other.data;
        } else {
            @compileError("todo");
        }
    }
    pub fn format(err: PostError, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (builtin.os.tag == .windows) {
            try writer.print("{f}", .{err.data});
        } else {
            @compileError("todo");
        }
    }
};
const Target = struct {
    data: if (builtin.os.tag == .windows) struct {
        hwnd: win32.HWND,
        msg: u32,
    } else struct {},

    pub fn post(target: *const Target, action: PostAction, out_err: *PostError) error{Post}!void {
        if (builtin.os.tag == .windows) {
            const args = action.serialize();
            if (0 == win32.PostMessageW(target.data.hwnd, target.data.msg, args.wparam, args.lparam)) {
                out_err.* = .{ .data = win32.GetLastError() };
                return error.Post;
            }
        } else {
            @panic("todo");
        }
    }
};

const SubclassWindowState = union(enum) {
    initial: struct {
        register_error: ?win32.WIN32_ERROR = null,
    },
    find_window: struct {
        enum_windows_error: ?win32.WIN32_ERROR = null,
        candidate_count: ?u32 = null,
    },
    subclass: struct {
        set_wndproc_error: ?win32.WIN32_ERROR = null,
    },
    ready,
};
fn subclassUpdate() enum { keep_calling, done } {
    state: switch (global.subclass.state) {
        .initial => |*state| {
            global.subclass.wnd_msg = win32.RegisterWindowMessageW(win32.L("MutinyMainThread"));
            if (global.subclass.wnd_msg == 0) {
                const err = win32.GetLastError();
                coalescedLog(
                    ?win32.WIN32_ERROR,
                    &state.register_error,
                    err,
                    .err,
                    "RegisterWindowMessage failed, error={f}",
                    .{err},
                );
                return .keep_calling;
            }
            global.subclass.state = .{ .find_window = .{} };
            continue :state global.subclass.state;
        },
        .find_window => |*state| {
            var ctx: FindContext = .{ .pid = win32.GetCurrentProcessId() };
            if (win32.EnumWindows(findUnityWindowProc, @bitCast(@intFromPtr(&ctx))) == 0) {
                const err = win32.GetLastError();
                coalescedLog(
                    ?win32.WIN32_ERROR,
                    &state.enum_windows_error,
                    err,
                    .err,
                    "EnumWindows failed, error={f}",
                    .{err},
                );
                return .keep_calling;
            }

            if (ctx.candidate_count != 1) {
                coalescedLog(
                    ?u32,
                    &state.candidate_count,
                    ctx.candidate_count,
                    .info,
                    "{} main unity window candidates",
                    .{ctx.candidate_count},
                );
                return .keep_calling;
            }
            const window = &ctx.first_candidate.?;
            std.log.info("found unity window 0x{x} on thread {}", .{ @intFromPtr(window.hwnd), window.tid });
            global.subclass.hwnd = window.hwnd;
            global.subclass.state = .{ .subclass = .{} };
            continue :state global.subclass.state;
        },
        .subclass => |*state| {
            const old_wndproc, const set_error = blk: {
                global.subclass.wndproc.mutex.lock();
                defer global.subclass.wndproc.mutex.unlock();
                win32.SetLastError(.NO_ERROR);
                const old_wndproc = win32.setWindowLongPtrW(
                    global.subclass.hwnd,
                    @intFromEnum(win32.GWLP_WNDPROC),
                    @intFromPtr(&subclassProc),
                );
                const err = win32.GetLastError();
                if (old_wndproc != 0) global.subclass.wndproc.ptr = @ptrFromInt(old_wndproc);
                break :blk .{ old_wndproc, err };
            };
            if (old_wndproc == 0) {
                coalescedLog(
                    ?win32.WIN32_ERROR,
                    &state.set_wndproc_error,
                    set_error,
                    .err,
                    "SetWindowLongPtr failed, error={f}",
                    .{set_error},
                );
                switch (set_error) {
                    .ERROR_INVALID_WINDOW_HANDLE => {
                        global.subclass.state = .{ .find_window = .{} };
                        continue :state global.subclass.state;
                    },
                    else => {},
                }
                return .keep_calling;
            }
            std.log.info("mainthread: subclassed window 0x{x} (original wndproc 0x{x})", .{
                @intFromPtr(global.subclass.hwnd),
                old_wndproc,
            });
            global.subclass.state = .ready;
            continue :state global.subclass.state;
        },
        .ready => return .done,
    }
}

fn ThreadSet(comptime capacity: usize) type {
    return struct {
        array: BoundedArray(u32, capacity) = .{},
        overflow: bool = false,

        const Self = @This();
        pub fn add(set: *Self, tid: u32) void {
            if (set.overflow) return;
            if (set.array.len == capacity) {
                set.overflow = true;
                return;
            }
            for (set.array.buffer[0..set.array.len]) |existing| {
                if (existing == tid) return;
            }
            set.array.buffer[set.array.len] = tid;
            set.array.len += 1;
        }
    };
}

const FindContext = struct {
    pid: u32,
    candidate_count: u32 = 0,
    first_candidate: ?struct {
        hwnd: win32.HWND,
        tid: u32,
    } = null,
    all_window_threads: ThreadSet(8) = .{},
    unity_window_threads: ThreadSet(8) = .{},
};

const GetWindowThreadProcessIdError = error{
    InvalidHandle,
    Unexpected,
};
fn GetWindowThreadProcessId(hwnd: win32.HWND) GetWindowThreadProcessIdError!struct { u32, u32 } {
    var pid: u32 = 0;
    const tid = win32.GetWindowThreadProcessId(hwnd, &pid);
    return if (tid == 0) switch (win32.GetLastError()) {
        win32.WIN32_ERROR.ERROR_INVALID_WINDOW_HANDLE => error.InvalidHandle,
        else => |e| {
            std.log.err("GetWindowThreadProcessId unexpectd error: {f}", .{e});
            return error.Unexpected;
        },
    } else .{ tid, pid };
}

const GetClassNameError = error{
    InvalidHandle,
    Unexpected,
};
pub fn GetClassName(hwnd: win32.HWND, buf: []u16) GetClassNameError!usize {
    std.debug.assert(buf.len > 0);
    const len = win32.GetClassNameW(hwnd, @ptrCast(buf.ptr), @intCast(buf.len));
    if (len == 0) switch (win32.GetLastError()) {
        win32.WIN32_ERROR.ERROR_INVALID_WINDOW_HANDLE => return error.InvalidHandle,
        else => |e| {
            std.log.err("GetClassName unexpected error: {f}", .{e});
            return error.Unexpected;
        },
    };
    if (len < 0) unreachable;
    if (len > buf.len) unreachable; // GetClassNameW silently truncates
    return @intCast(len);
}

const unity_window_class = std.unicode.utf8ToUtf16LeStringLiteral("UnityWndClass");
fn findUnityWindowProc(hwnd: win32.HWND, lparam: win32.LPARAM) callconv(.winapi) win32.BOOL {
    const ctx: *FindContext = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const tid, const pid = GetWindowThreadProcessId(hwnd) catch |err| switch (err) {
        error.InvalidHandle => return win32.TRUE, // window gone, skip
        error.Unexpected => @panic("GetWindowThreadProcessId unexpected error"),
    };
    if (pid != ctx.pid) return win32.TRUE; // not ours
    ctx.all_window_threads.add(tid);
    var class_name_buf: [64:0]u16 = undefined;
    const class_name = class_name_buf[0 .. GetClassName(hwnd, &class_name_buf) catch |err| switch (err) {
        error.InvalidHandle => return win32.TRUE, // window gone, skip
        error.Unexpected => @panic("GetClassName unexpected error"),
    }];
    const owned = win32.GetWindow(hwnd, win32.GW_OWNER) != null;
    if (owned) return win32.TRUE; // ignore child windows
    // TODO: should we filter on visible windows? probably not?
    // const visible = win32.IsWindowVisible(hwnd) != 0;
    if (!std.mem.eql(u16, class_name, unity_window_class)) return win32.TRUE;
    ctx.unity_window_threads.add(tid);
    ctx.candidate_count += 1;
    if (ctx.first_candidate == null) {
        ctx.first_candidate = .{ .hwnd = hwnd, .tid = tid };
    }
    return win32.TRUE; // never stop early, so EnumWindows returning FALSE is unambiguously an error
}

fn subclassProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == global.subclass.wnd_msg) {
        const action = PostAction.deserialize(.{ .wparam = wparam, .lparam = lparam }) orelse {
            std.log.err("unknown wparam 0x{x} lparam 0x{x}", .{ wparam, lparam });
            return 0;
        };
        switch (action) {
            .bootstrap => switch (bootstrap()) {
                .retry => {},
                .installed => global.bootstrap_state.store(.installed, .monotonic),
                .failed => global.bootstrap_state.store(.failed, .monotonic),
            },
            .subclass_self_test => {
                std.log.info("TODO: run subclass self test", .{});
            },
        }
        return 0;
    }
    const wndproc = blk: {
        global.subclass.wndproc.mutex.lock();
        defer global.subclass.wndproc.mutex.unlock();
        break :blk global.subclass.wndproc.ptr;
    };
    return win32.CallWindowProcW(wndproc, hwnd, msg, wparam, lparam);
}

const DotNetLib = struct {
    kind: dotnet.Kind,
    module: dynlib.Module,
};

fn initMono() ?win32.HINSTANCE {
    if (win32.GetModuleHandleW(win32.L(dotnet.dll_name_mono))) |mono_mod| {
        std.log.info("module \"{s}\" at 0x{x}", .{ dotnet.dll_name_mono, @intFromPtr(mono_mod) });
        return mono_mod;
    }
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => {
            std.log.info("{s}: not found yet...", .{dotnet.dll_name_mono});
            return null;
        },
        else => |e| std.debug.panic("GetModule '{s}' failed, error={f}", .{ dotnet.dll_name_mono, e }),
    }
}
fn initIl2cpp() ?win32.HINSTANCE {
    if (win32.GetModuleHandleW(win32.L(dotnet.dll_name_il2cpp))) |mod| {
        std.log.info("module \"{s}\" at 0x{x}", .{ dotnet.dll_name_il2cpp, @intFromPtr(mod) });
        return mod;
    }
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => {
            std.log.info("{s}: not found yet...", .{dotnet.dll_name_il2cpp});
            return null;
        },
        else => |e| std.debug.panic("GetModule '{s}' failed, error={f}", .{ dotnet.dll_name_il2cpp, e }),
    }
}

const RuntimeState = union(enum) {
    find_lib: struct {
        no_module_logged: bool = false,
    },
    init_funcs: struct {
        lib: DotNetLib,
    },
    wait_domain: struct {
        module: dynlib.Module,
        no_domain_logged: bool = false,
    },
    unrecoverable_error: UnrecoverableError,
    ready: struct {
        module: dynlib.Module,
        root_domain: *const dotnet.Domain,
    },

    const UnrecoverableError = union(enum) {
        missing_proc: struct {
            lib: DotNetLib,
            name: [:0]const u8,
        },

        pub fn format(err: UnrecoverableError, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (err) {
                .missing_proc => |e| try writer.print("{t} runtime is missing '{s}'", .{ e.lib.kind, e.name }),
            }
        }
    };
};

const UpdateHookState = union(enum) {
    pending,
    mono_instantiate: struct {
        ticker: *const dotnet.Class,
        not_ready_logged: ?mutinymono.InstantiateError = null,
    },
    installed,
    failed: struct {
        err: Error,
        update_mods_warned: bool = false,
    },

    const Error = union(enum) {
        mono: mutinymono.Error,
        il2cpp: BootstrapIl2cppError,
    };
};

const BootstrapResult = enum { retry, installed, failed };

fn updateUpdateHook(
    dotnet_funcs: *const dotnet.Funcs,
    module: dynlib.Module,
    root_domain: *const dotnet.Domain,
) BootstrapResult {
    state: switch (global.update_hook) {
        .pending => switch (dotnet_funcs.kind) {
            .mono => {
                const ticker = mutinymono.load(dotnet_funcs) catch |err| {
                    std.log.err("loading the embedded MutinyMono.dll failed ({t}), mods will not run", .{err});
                    global.update_hook = .{ .failed = .{ .err = .{ .mono = err } } };
                    return .failed;
                };
                global.update_hook = .{ .mono_instantiate = .{ .ticker = ticker } };
                continue :state global.update_hook;
            },
            .il2cpp => {
                bootstrapIl2cpp(dotnet_funcs, module, root_domain) catch |err| {
                    std.log.err("il2cpp Update hook failed to install ({t}), mods will not run", .{err});
                    global.update_hook = .{ .failed = .{ .err = .{ .il2cpp = err } } };
                    return .failed;
                };
                global.update_hook = .installed;
                return .installed;
            },
        },
        .mono_instantiate => |*hook| {
            mutinymono.instantiate(dotnet_funcs, hook.ticker) catch |err| switch (err) {
                error.MissingAssembly => {
                    coalescedLog(
                        ?mutinymono.InstantiateError,
                        &hook.not_ready_logged,
                        err,
                        .info,
                        "mono Update hook not installed yet ({t}), will retry",
                        .{err},
                    );
                    return .retry;
                },
                else => {
                    std.log.err("mono Update hook failed to install ({t}), mods will not run", .{err});
                    global.update_hook = .{ .failed = .{ .err = .{ .mono = err } } };
                    return .failed;
                },
            };
            global.update_hook = .installed;
            return .installed;
        },
        .installed => return .installed,
        .failed => |*hook| {
            mods.applyUpdates(dotnet_funcs);
            const has_mods = mods.hasMods();
            if (has_mods and !hook.update_mods_warned) {
                std.log.err("mods will not run: the Update hook failed to install (see the error above)", .{});
            }
            hook.update_mods_warned = has_mods;
            failQueuedScripts(.update_hook_failed);
            return .failed;
        },
    }
}
fn updateRuntime() union(enum) {
    not_ready,
    unrecoverable_error: RuntimeState.UnrecoverableError,
    ready: *const dotnet.Funcs,
} {
    state: switch (global.runtime) {
        .find_lib => |*runtime| {
            const lib: DotNetLib = blk: {
                if (initMono()) |module| break :blk .{ .kind = .mono, .module = module };
                if (initIl2cpp()) |module| break :blk .{ .kind = .il2cpp, .module = module };
                coalescedLog(
                    bool,
                    &runtime.no_module_logged,
                    true,
                    .info,
                    "no mono nor il2cpp module yet",
                    .{},
                );
                return .not_ready;
            };
            global.runtime = .{ .init_funcs = .{ .lib = lib } };
            continue :state global.runtime;
        },
        .init_funcs => |*runtime| {
            var missing_proc: [:0]const u8 = undefined;
            global.dotnet_funcs_store = dotnet.Funcs.init(
                &missing_proc,
                runtime.lib.kind,
                runtime.lib.module,
            ) catch {
                // I'm pretty sure a missing function is not recoverable,
                // the library isn't going to magically spawn a new function
                std.log.err(
                    "{t} dotnet missing proc '{s}'",
                    .{ runtime.lib.kind, missing_proc },
                );
                global.runtime = .{ .unrecoverable_error = .{ .missing_proc = .{
                    .lib = runtime.lib,
                    .name = missing_proc,
                } } };
                continue :state global.runtime;
            };
            // ensure runtime does not appear in the assignment as we're re-assigning it
            const module = runtime.lib.module;
            global.runtime = .{ .wait_domain = .{ .module = module } };
            continue :state global.runtime;
        },
        .wait_domain => |*runtime| {
            const root_domain = global.dotnet_funcs_store.get_root_domain() orelse {
                coalescedLog(
                    bool,
                    &runtime.no_domain_logged,
                    true,
                    .info,
                    "dotnet loaded but root domain not ready yet",
                    .{},
                );
                return .not_ready;
            };
            // ensure runtime does not appear in the assignment as we're re-assigning it
            const module = runtime.module;
            global.runtime = .{ .ready = .{ .module = module, .root_domain = root_domain } };
            continue :state global.runtime;
        },
        .unrecoverable_error => |e| return .{ .unrecoverable_error = e },
        .ready => return .{ .ready = &global.dotnet_funcs_store },
    }
}

const BootstrapIl2cppError = error{
    UnityPlayerNotLoaded,
    UnityVersionUnreadable,
} || il2cppclass.DiscoverError || detour.FindError || detour.InstallError || il2cppclass.SelfTestError || il2cppclass.InstantiateError;

fn bootstrapIl2cpp(
    dotnet_funcs: *const dotnet.Funcs,
    module: dynlib.Module,
    root_domain: *const dotnet.Domain,
) BootstrapIl2cppError!void {
    const player = win32.GetModuleHandleW(win32.L("UnityPlayer.dll")) orelse return error.UnityPlayerNotLoaded;
    std.log.info("module \"UnityPlayer.dll\" at 0x{x}", .{@intFromPtr(player)});
    const unity_version = UnityVersion.fromLoadedModule(player) catch |err| {
        std.log.err("could not read the unity version from UnityPlayer.dll ({t})", .{err});
        return error.UnityVersionUnreadable;
    };
    std.log.info("unity version: {f}", .{unity_version});

    const start = getNow();
    const layouts = try il2cppclass.discover(dotnet_funcs, unity_version);
    std.log.info("il2cpp layout verified in {} ms", .{getNow().since(start) / std.time.ns_per_ms});

    const target = try detour.findFunction(module, "il2cpp_class_from_il2cpp_type");
    const installed = try detour.install(target, @intFromPtr(&il2cppclass.fromIl2CppTypeHook));
    il2cppclass.global.fromIl2CppTypeOrig = @ptrFromInt(installed.trampoline);

    const handle_target = try detour.findTypeInfoFromTypeDefinitionIndex(module);
    const handle_installed = try detour.install(handle_target, @intFromPtr(&il2cppclass.typeInfoFromTypeDefinitionIndexHook));
    il2cppclass.global.typeInfoFromTypeDefinitionIndexOrig = @ptrFromInt(handle_installed.trampoline);
    std.log.info("il2cpp: GetTypeInfoFromTypeDefinitionIndex hook installed at +0x{x}", .{handle_target - @intFromPtr(module)});

    var assembly_count: usize = 0;
    const assemblies = dotnet_funcs.kind.il2cpp.domain_get_assemblies(root_domain, &assembly_count);
    try il2cppclass.subclassSelfTest(dotnet_funcs, assemblies[0..assembly_count], layouts, unity_version);
    std.log.info("il2cpp: FromIl2CppType hook installed, MonoBehaviour subclass built", .{});
    try il2cppclass.instantiate(dotnet_funcs, assemblies[0..assembly_count]);
}

// Note: this is called on EVERY game update, which can happen hundreds of times
//       per second. Be very cautious about performance and logging.
pub fn onUpdate() callconv(.c) void {
    std.debug.assert(!global.vm_pass_active);
    global.vm_pass_active = true;
    defer global.vm_pass_active = false;
    const dotnet_funcs = switch (updateRuntime()) {
        .ready => |funcs| funcs,
        .unrecoverable_error, .not_ready => return,
    };
    ipc.ensureWindow();
    mods.applyUpdates(dotnet_funcs);
    runScripts(dotnet_funcs);
    var it = mods.modIterator();
    while (it.next()) |mod| runMod(dotnet_funcs, mod);
}
pub fn onGui() callconv(.c) void {
    const dotnet_funcs = switch (updateRuntime()) {
        .ready => |funcs| funcs,
        .unrecoverable_error, .not_ready => return,
    };
    unitygui.draw(dotnet_funcs);
}

fn runMod(dotnet_funcs: *const dotnet.Funcs, mod: *Mod) void {
    std.debug.assert(arenaIsClear(&global.vm_arena));
    defer _ = global.vm_arena.reset(.retain_capacity);
    var vm: Vm = .{
        .dotnet_funcs = dotnet_funcs,
        .text = mod.text,
        .mem = .{ .allocator = global.vm_arena.allocator() },
        .out = .{ .result = &mod.status.buffer },
    };
    defer vm.deinit();
    const name = mod.name.slice();
    const new_state: Mod.State = if (vm.evalRoot()) .ok else |_| switch (vm.error_result) {
        .exit => .ok,
        .result => |result| blk: {
            std.debug.assert(result.ptr == &mod.status.buffer);
            mod.status.len = @intCast(result.len);
            break :blk .{ .result = .{ .wyhash = std.hash.Wyhash.hash(0, result) } };
        },
        .err => |err| switch (err) {
            .vm_out => unreachable, // no writer
            else => blk: {
                mod.formatStatus("{f}", .{err.fmt(mod.text, dotnet_funcs)});
                break :blk .{ .err = .{
                    .error_wyhash = std.hash.Wyhash.hash(0, mod.status.slice()),
                } };
            },
        },
    };
    if (!std.meta.eql(new_state, mod.state)) {
        switch (new_state) {
            .ok => {
                std.log.info("{s}: recovered", .{name});
                mod.formatStatus("enabled", .{});
            },
            .result => std.log.info("{s}: {s}", .{ name, mod.status.slice() }),
            .err => std.log.err("{s}:{s}", .{ name, mod.status.slice() }),
        }
        mod.state = new_state;
        std.debug.assert(std.meta.eql(new_state, mod.state));
    }
}

fn bootstrap() BootstrapResult {
    if (global.vm_pass_active) return .retry;
    const dotnet_funcs = switch (updateRuntime()) {
        .ready => |funcs| funcs,
        .unrecoverable_error => |err| {
            failQueuedScripts(.{ .runtime = err });
            return .failed;
        },
        .not_ready => return .retry,
    };
    const result = updateUpdateHook(
        dotnet_funcs,
        global.runtime.ready.module,
        global.runtime.ready.root_domain,
    );
    if (result == .installed and !ensureIoThread()) return .failed;
    return result;
}

fn runScripts(dotnet_funcs: *const dotnet.Funcs) void {
    while (scripts.take()) |script| {
        defer script.deinit();
        const pipe_file: std.fs.File = .{ .handle = script.client.pipe };
        var pipe_buf: [4096]u8 = undefined;
        var pipe_writer = pipe_file.writerStreaming(&pipe_buf);
        var write_error: ?error{WriteFailed} = null;
        switch (script.kind) {
            .builtin => |builtin_script| runBuiltin(
                dotnet_funcs,
                builtin_script,
                &pipe_writer.interface,
            ) catch |e| {
                write_error = e;
            },
            .file => |*file| runOne(
                dotnet_funcs,
                script.name.slice(),
                file.text,
                &pipe_writer.interface,
            ) catch |e| {
                write_error = e;
            },
        }
        // just in case we forgot to flush
        if (write_error == null) pipe_writer.interface.flush() catch |e| {
            write_error = e;
        };
        if (write_error != null) {
            std.log.err("write to pipe failed with {t}", .{pipe_writer.err.?});
        }
    }
}

const ScriptFailReason = union(enum) {
    runtime: RuntimeState.UnrecoverableError,
    update_hook_failed,

    pub fn format(reason: ScriptFailReason, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (reason) {
            .runtime => |err| try writer.print("{f}", .{err}),
            .update_hook_failed => try writer.writeAll("the Update hook failed to install"),
        }
    }
};

fn failQueuedScripts(reason: ScriptFailReason) void {
    while (scripts.take()) |script| {
        defer script.deinit();
        std.log.err("rejecting script '{s}': {f}", .{ script.name.slice(), reason });
        const pipe_file: std.fs.File = .{ .handle = script.client.pipe };
        var pipe_buf: [512]u8 = undefined;
        var pipe_writer = pipe_file.writerStreaming(&pipe_buf);
        const write_error: ?error{WriteFailed} = blk: {
            pipe_writer.interface.print(
                "error: mutiny cannot run scripts in this process, {f}\n",
                .{reason},
            ) catch |e| break :blk e;
            pipe_writer.interface.flush() catch |e| break :blk e;
            break :blk null;
        };
        if (write_error != null) {
            std.log.err("write to pipe failed with {t}", .{pipe_writer.err.?});
        }
    }
}

fn getNow() std.time.Instant {
    return std.time.Instant.now() catch |err| std.debug.panic("Instant.now failed with {t}", .{err});
}

fn runOne(
    dotnet_funcs: *const dotnet.Funcs,
    name: []const u8,
    text: []const u8,
    out: *std.Io.Writer,
) error{WriteFailed}!void {
    std.debug.assert(arenaIsClear(&global.vm_arena));
    defer _ = global.vm_arena.reset(.retain_capacity);

    var vm: Vm = .{
        .dotnet_funcs = dotnet_funcs,
        .text = text,
        .mem = .{ .allocator = global.vm_arena.allocator() },
        .out = .{ .pipe = out },
    };
    defer vm.deinit();
    vm.evalRoot() catch switch (vm.error_result) {
        .exit => std.log.info("{s} has exited", .{name}),
        .result => unreachable, // out is never .result here
        .err => |err| switch (err) {
            .vm_out => return error.WriteFailed,
            else => {
                std.log.err("{s}:{f}", .{ name, err.fmt(text, dotnet_funcs) });
                try out.print("{s}: error:{f}\n", .{ name, err.fmt(text, dotnet_funcs) });
            },
        },
    };
    try out.flush();
}

fn runBuiltin(
    dotnet_funcs: *const dotnet.Funcs,
    builtin_script: Builtin,
    writer: *std.Io.Writer,
) error{WriteFailed}!void {
    switch (builtin_script) {
        .assemblies => try builtins.writeAssemblies(dotnet_funcs, writer, .names),
        .decomp => try builtins.writeDecomp(dotnet_funcs, writer),
    }
    try writer.flush();
}

pub const Builtin = enum {
    assemblies,
    decomp,
};

const ModUpdate = union(enum) {
    open_file_error: std.fs.File.OpenError,
    file_size_error: std.fs.File.GetEndPosError,
    file_too_big: u64,
    out_of_memory,
    read_file_error: anyerror,
    content: []const u8,
};

pub fn arenaIsClear(arena: *std.heap.ArenaAllocator) bool {
    if (arena.state.end_index != 0) return false;
    const first = arena.state.buffer_list.first orelse return true;
    return first.next == null;
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");
const builtins = @import("builtins.zig");
const detour = mutiny.detour;
const dotnet = mutiny.dotnet;
const dynlib = mutiny.dynlib;
const il2cppclass = mutiny.il2cppclass;
const io = @import("dll.io");
const ipc = @import("ipc.zig");
const mods = @import("mods.zig");
const unitygui = @import("unitygui.zig");
const mutinymono = mutiny.mutinymono;
const scripts = @import("scripts.zig");

const Mod = @import("Mod.zig");
const UnityVersion = mutiny.UnityVersion;
const Vm = mutiny.Vm;
