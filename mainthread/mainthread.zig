pub const appdata = mutiny.appdata;
pub const logfile = mutiny.logfile;
pub const mutinyipc = mutiny.mutinyipc;

pub const BoundedArray = mutiny.BoundedArray;
pub const ModNameSlice = @import("ModNameSlice.zig");
pub const Mutex = mutiny.Mutex;
pub const Pool = mutiny.Pool;

pub const mutinyThreadQueueModUpdate = mods.mutinyThreadQueueUpdate;
pub const mutinyThreadQueueModRemove = mods.mutinyThreadQueueRemove;
pub const mutinyThreadQueueScript = scripts.mutinyThreadQueue;
pub const ScriptRequest = scripts.Request;

const global = struct {
    var shared: struct {
        mutex: Mutex = .{},
        mutiny_hwnd: ?win32.HWND = null,
        init_state: InitState = .idle,
    } = .{};
    var state: State = .{ .initial = .{} };
    var wnd_msg: u32 = undefined;
    var hwnd: win32.HWND = undefined;
    var subclass: struct {
        mutex: std.Thread.Mutex = .{},
        wndproc: win32.WNDPROC = undefined,
    } = .{};

    var post_retry_enabled: std.atomic.Value(bool) = .init(false);
    var run_mods_error: ?RunModsError = null;
    var dotnet_funcs_store: dotnet.Funcs = undefined;
    var dotnet_funcs: ?*dotnet.Funcs = null;
    var inside_run: bool = false;
    var vm_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
};

const InitState = union(enum) {
    idle,
    initializing,
    complete,
};

pub const wm_schedule_rerun = win32.WM_USER + 0;

pub fn mutinyThreadSetHwnd(hwnd: win32.HWND) void {
    global.shared.mutex.lock();
    defer global.shared.mutex.unlock();
    std.debug.assert(global.shared.mutiny_hwnd == null);
    global.shared.mutiny_hwnd = hwnd;
}
pub fn mutinyThreadUnsetHwnd(hwnd: win32.HWND) void {
    global.shared.mutex.lock();
    defer global.shared.mutex.unlock();
    std.debug.assert(global.shared.mutiny_hwnd == hwnd);
    global.shared.mutiny_hwnd = null;
}

fn scheduleRerun(ms: u32) error{Schedule}!void {
    // NOTE: if we post too often it can cause starve the game
    //       so we still do the thread hop even in this case
    // if (ms == 0) {
    //     const target: Target = .{ .data = .{ .hwnd = global.hwnd, .msg = global.wnd_msg } };
    //     var err: PostError = undefined;
    //     target.post(.run, &err) catch {
    //         std.log.err("PostMessage(rerun) failed, error={f}", .{err});
    //         return error.Schedule;
    //     };
    //     return;
    // }
    global.shared.mutex.lock();
    defer global.shared.mutex.unlock();
    const hwnd = global.shared.mutiny_hwnd orelse {
        std.log.err("cannot schedule a rerun in {} ms, the mutiny window is gone", .{ms});
        return error.Schedule;
    };
    if (0 == win32.PostMessageW(hwnd, wm_schedule_rerun, ms, 0)) {
        std.log.err("PostMessage(schedule rerun) failed, error={f}", .{win32.GetLastError()});
        return error.Schedule;
    }
}

const State = union(enum) {
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

pub const PostResult = union(enum) {
    posted,
    not_ready,
    post_error: PostError,
};

pub fn mutinyThreadOnTick(last_post_result: *PostResult) void {
    switch (last_post_result.*) {
        .posted => {},
        .not_ready, .post_error => {
            mutinyThreadPostRun(last_post_result);
            return;
        },
    }
    if (global.post_retry_enabled.load(.monotonic)) {
        mutinyThreadPostRun(last_post_result);
    }
}
pub fn mutinyThreadPostRun(last_post_result: *PostResult) void {
    const new_result: PostResult = blk: switch (global.state) {
        .initial, .find_window, .subclass => .not_ready,
        .ready => {
            const target: Target = .{ .data = .{ .hwnd = global.hwnd, .msg = global.wnd_msg } };
            var err: PostError = undefined;
            target.post(.run, &err) catch break :blk .{ .post_error = err };
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
    run,
    subclass_self_test,
    pub fn deserialize(args: PostActionArgs) ?PostAction {
        if (builtin.os.tag == .windows) {
            return switch (args.wparam) {
                1 => return .run,
                2 => return .subclass_self_test,
                else => null,
            };
        } else @panic("todo");
    }
    pub fn serialize(action: PostAction) PostActionArgs {
        if (builtin.os.tag == .windows) return switch (action) {
            .run => .{ .wparam = 1, .lparam = undefined },
            .subclass_self_test => .{ .wparam = 2, .lparam = undefined },
        } else @panic("todo");
    }
};

pub const PostError = struct {
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

pub fn mutinyThreadDetach() bool {
    std.log.err("TODO: implement mainthread.mutinyThreadDetach", .{});
    return false;
}

pub fn mutinyThreadInitUpdate() enum { keep_calling, done } {
    state: switch (global.state) {
        .initial => |*state| {
            global.wnd_msg = win32.RegisterWindowMessageW(win32.L("MutinyMainThread"));
            if (global.wnd_msg == 0) {
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
            global.state = .{ .find_window = .{} };
            continue :state global.state;
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
            global.hwnd = window.hwnd;
            global.state = .{ .subclass = .{} };
            continue :state global.state;
        },
        .subclass => |*state| {
            const old_wndproc, const set_error = blk: {
                global.subclass.mutex.lock();
                defer global.subclass.mutex.unlock();
                win32.SetLastError(.NO_ERROR);
                const old_wndproc = win32.setWindowLongPtrW(
                    global.hwnd,
                    @intFromEnum(win32.GWLP_WNDPROC),
                    @intFromPtr(&subclassProc),
                );
                const err = win32.GetLastError();
                if (old_wndproc != 0) global.subclass.wndproc = @ptrFromInt(old_wndproc);
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
                        global.state = .{ .find_window = .{} };
                        continue :state global.state;
                    },
                    else => {},
                }
                return .keep_calling;
            }
            std.log.info("mainthread: subclassed window 0x{x} (original wndproc 0x{x})", .{
                @intFromPtr(global.hwnd),
                old_wndproc,
            });
            global.state = .ready;
            continue :state global.state;
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
    if (msg == global.wnd_msg) {
        const action = PostAction.deserialize(.{ .wparam = wparam, .lparam = lparam }) orelse {
            std.log.err("unknown wparam 0x{x} lparam 0x{x}", .{ wparam, lparam });
            return 0;
        };
        switch (action) {
            .run => global.post_retry_enabled.store(switch (run()) {
                .success => false,
                .fail => true,
                // next run above us in the stack will set this to true if needed
                .recursed => false,
            }, .monotonic),
            .subclass_self_test => {
                std.log.info("TODO: run subclass self test", .{});
            },
        }
        return 0;
    }
    const wndproc = blk: {
        global.subclass.mutex.lock();
        defer global.subclass.mutex.unlock();
        break :blk global.subclass.wndproc;
    };
    return win32.CallWindowProcW(wndproc, hwnd, msg, wparam, lparam);
}

const DotNetLib = struct {
    kind: dotnet.Kind,
    module: dynlib.Module,
};

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

const RunModsError = union(enum) {
    no_dotnet_lib,
    no_root_domain,
    missing_proc: struct {
        lib_kind: dotnet.Kind,
        name: [:0]const u8,
    },
};

fn run() enum { success, fail, recursed } {
    if (global.inside_run) return .recursed;
    global.inside_run = true;
    defer global.inside_run = false;
    var rerun_schedule_failed = false;

    if (global.dotnet_funcs == null) {
        const lib: DotNetLib = blk: {
            if (initMono()) |module| break :blk .{ .kind = .mono, .module = module };
            if (initIl2cpp()) |module| break :blk .{ .kind = .il2cpp, .module = module };
            coalescedLog(
                ?RunModsError,
                &global.run_mods_error,
                .no_dotnet_lib,
                .info,
                "no mono nor il2cpp module yet",
                .{},
            );
            return .fail;
        };

        global.dotnet_funcs_store = blk: {
            var missing_proc: [:0]const u8 = undefined;
            break :blk dotnet.Funcs.init(&missing_proc, lib.kind, lib.module) catch {
                coalescedLog(
                    ?RunModsError,
                    &global.run_mods_error,
                    .{ .missing_proc = .{
                        .lib_kind = lib.kind,
                        .name = missing_proc,
                    } },
                    .err,
                    "{t} dotnet missing proc '{s}'",
                    .{ lib.kind, missing_proc },
                );
                return .fail;
            };
        };
        global.dotnet_funcs = &global.dotnet_funcs_store;
    }
    const dotnet_funcs = global.dotnet_funcs.?;

    // "module loaded" doesn't mean "runtime up": if the root domain isn't ready yet, bail so
    // the retry re-posts rather than invoking managed code against a null domain.
    if (dotnet_funcs.get_root_domain() == null) {
        coalescedLog(
            ?RunModsError,
            &global.run_mods_error,
            .no_root_domain,
            .info,
            "dotnet loaded but root domain not ready yet",
            .{},
        );
        return .fail;
    }

    mods.applyUpdates();
    {
        const now = getNow();
        var it = mods.iterator();
        while (it.next(now)) |mod| {
            const maybe_rerun_ms = runOne(dotnet_funcs, mod.name.slice(), mod.text.?, mod.is_first_run, null) catch |err| switch (err) {
                error.WriteFailed => unreachable, // did not pass a writer
            };
            mod.is_first_run = false;
            if (maybe_rerun_ms) |ms| {
                mod.run = .{ .rerun = .{ .scheduled = now, .delay_ms = ms } };
            }
        }
        if (mods.nextRerunMs(getNow())) |ms| scheduleRerun(ms) catch |err| switch (err) {
            error.Schedule => rerun_schedule_failed = true,
        };
    }

    while (scripts.steal()) |script| {
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
            .file => |*file| _ = runOne(
                dotnet_funcs,
                script.name.slice(),
                file.text,
                true,
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

    return if (rerun_schedule_failed) .fail else .success;
}

fn getNow() std.time.Instant {
    return std.time.Instant.now() catch |err| std.debug.panic("Instant.now failed with {t}", .{err});
}

fn runOne(
    dotnet_funcs: *const dotnet.Funcs,
    name: []const u8,
    text: []const u8,
    is_first_run: bool,
    out: ?*std.Io.Writer,
) error{WriteFailed}!?u32 {
    std.debug.assert(arenaIsClear(&global.vm_arena));
    defer _ = global.vm_arena.reset(.retain_capacity);

    var vm: Vm = .{
        .dotnet_funcs = dotnet_funcs,
        .text = text,
        .mem = .{ .allocator = global.vm_arena.allocator() },
        .out = out,
        .is_first_run = is_first_run,
    };
    defer vm.deinit();
    var rerun_ms: ?u32 = null;
    vm.evalRoot() catch switch (vm.error_result) {
        .exit => std.log.info("{s} has exited", .{name}),
        .rerun_ms => |ms| if (out) |w| {
            std.log.err("{s}: @Rerun is only supported in mods", .{name});
            try w.print("{s}: error: @Rerun is only supported in mods\n", .{name});
        } else {
            std.log.debug("{s} will rerun in {} ms", .{ name, ms });
            rerun_ms = ms;
        },
        .err => |err| switch (err) {
            .vm_out => return error.WriteFailed,
            else => {
                std.log.err("{s}:{f}", .{ name, err.fmt(text, dotnet_funcs) });
                if (out) |w| try w.print("{s}: error:{f}\n", .{ name, err.fmt(text, dotnet_funcs) });
            },
        },
    };
    if (out) |w| try w.flush();
    return rerun_ms;
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
const dotnet = mutiny.dotnet;
const dynlib = mutiny.dynlib;
const mods = @import("mods.zig");
const scripts = @import("scripts.zig");

const Mod = @import("Mod.zig");
const Vm = mutiny.Vm;
