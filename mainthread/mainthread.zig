pub const appdata = mutiny.appdata;
pub const logfile = mutiny.logfile;
pub const mutinyipc = mutiny.mutinyipc;

pub const Mutex = mutiny.Mutex;

// use WM_USER so this is a private message to this process
pub const wm_mutiny_init_ack = win32.WM_USER + 0;

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
};

const InitState = union(enum) {
    idle,
    initializing,
    complete,
};

pub fn setHwnd(hwnd: win32.HWND) void {
    global.shared.mutex.lock();
    defer global.shared.mutex.unlock();
    std.debug.assert(global.shared.mutiny_hwnd == null);
    global.shared.mutiny_hwnd = hwnd;
}
pub fn unsetHwnd(hwnd: win32.HWND) void {
    global.shared.mutex.lock();
    defer global.shared.mutex.unlock();
    std.debug.assert(global.shared.mutiny_hwnd == hwnd);
    global.shared.mutiny_hwnd = null;
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
    post_init: struct {
        post_error: ?PostError = null,
    },
    init_posted,
    // initialized,
};

fn coalescedLog(
    comptime T: type,
    store: *T,
    new_value: T,
    comptime kind: enum { err, info },
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (eql(T, &new_value, store)) return;
    switch (kind) {
        .err => std.log.err(fmt, args),
        .info => std.log.info(fmt, args),
    }
    store.* = new_value;
    std.debug.assert(eql(T, &new_value, store));
}

fn eql(comptime T: type, a: *const T, b: *const T) bool {
    if (T == ?win32.WIN32_ERROR or T == ?u32) return a.* == b.*;
    if (T == ?PostError) {
        if (a.* == null) return b.* == null;
        return std.meta.eql(&a.*.?, &b.*.?);
    }
    @compileError("todo: implement eql for " ++ @typeName(T));
}

const PostActionArgs = if (builtin.os.tag == .windows) struct {
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
} else struct {};

pub const PostAction = union(enum) {
    init,
    subclass_self_test,
    pub fn deserialize(args: PostActionArgs) ?PostAction {
        if (builtin.os.tag == .windows) {
            return switch (args.wparam) {
                1 => return .init,
                2 => return .subclass_self_test,
                else => null,
            };
        } else @panic("todo");
    }
    pub fn serialize(action: PostAction) PostActionArgs {
        if (builtin.os.tag == .windows) return switch (action) {
            .init => .{ .wparam = 1, .lparam = undefined },
            .subclass_self_test => .{ .wparam = 2, .lparam = undefined },
        } else @panic("todo");
    }
};

pub const PostError = struct {
    data: if (builtin.os.tag == .windows) win32.WIN32_ERROR else void,
    pub fn format(e: PostError, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (builtin.os.tag == .windows) {
            try writer.print("{f}", .{e.data});
        } else {
            @compileError("todo");
        }
    }
};
pub const Target = struct {
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
// pub fn getInitializedTarget() ?Target {
//     return switch (global.state) {
//         .initial,
//         .find_window,
//         .subclass,
//         .post_init, // has hwnd/msg but it's not initialized yet
//         .init_posted, // has hwnd/msg but it's not initialized yet
//         => null,
//         // .init_posted => .{ .data = .{ .hwnd = global.hwnd, .msg = global.wnd_msg } },
//         // .installed =>
//     };
// }

pub fn onInitAck() void {
    global.shared.mutex.lock();
    defer global.shared.mutex.unlock();
    switch (global.shared.init_state) {
        .idle, .initializing => {
            std.log.warn(
                "mutiny thread received wm_mutiny_init_ack({d}) with init state {t}",
                .{ wm_mutiny_init_ack, global.shared.init_state },
            );
        },
        .complete => {
            switch (global.state) {
                .initial, .find_window, .subclass, .post_init => {
                    std.log.warn("mutiny thread received wm_mutiny_init_ack but hasn't posted init", .{});
                },
                .init_posted => {},
            }
        },
    }
}

// should be called by the mutiny thread
pub fn update() enum { keep_timer, kill_timer } {
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
                    "RegiserWindowMessage failed, error={f}",
                    .{err},
                );
                return .keep_timer;
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
                return .keep_timer;
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
                return .keep_timer;
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
                return .keep_timer;
            }
            std.log.info("mainthread: subclassed window 0x{x} (original wndproc 0x{x})", .{
                @intFromPtr(global.hwnd),
                old_wndproc,
            });
            global.state = .{ .post_init = .{} };
            continue :state global.state;
        },
        .post_init => |*state| {
            const target: Target = .{ .data = .{ .hwnd = global.hwnd, .msg = global.wnd_msg } };
            var err: PostError = undefined;
            target.post(.init, &err) catch {
                coalescedLog(?PostError, &state.post_error, err, .err, "PostMessage failed, error={f}", .{err});
                return .keep_timer;
            };
            global.state = .init_posted;
            continue :state global.state;
        },
        .init_posted => return .kill_timer,
    }
}

fn BoundedArray(comptime T: type, buffer_capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [buffer_capacity]T = undefined,
        len: usize = 0,
    };
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

fn lockedSendInitAck() void {
    if (global.shared.mutiny_hwnd == null) {
        std.log.warn("mutiny thread hwnd gone after init complete", .{});
    } else if (0 == win32.PostMessageW(global.shared.mutiny_hwnd, wm_mutiny_init_ack, 0, 0)) {
        // failing to post would result in mutiny waiting forever, and, the lock should prevent
        // the hwnd from being destroyed so, this should always work, no need to
        // handle if it doesn't, panic helps surface counterexample if it exists.
        std.debug.panic(
            "PostMessage for wm_mutiny_init_ack failed, error={f}",
            .{win32.GetLastError()},
        );
    }
}

fn subclassProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == global.wnd_msg) {
        const action = PostAction.deserialize(.{ .wparam = wparam, .lparam = lparam }) orelse {
            std.log.err("unknown wparam 0x{x} lparam 0x{x}", .{ wparam, lparam });
            return 0;
        };
        switch (action) {
            .init => {
                {
                    global.shared.mutex.lock();
                    defer global.shared.mutex.unlock();
                    switch (global.shared.init_state) {
                        .idle => global.shared.init_state = .initializing,
                        .initializing => {
                            std.log.err("main thread received init while already initialinzg?", .{});
                            return 0;
                        },
                        .complete => {
                            lockedSendInitAck();
                            return 0;
                        },
                    }
                }

                init();

                {
                    global.shared.mutex.lock();
                    defer global.shared.mutex.unlock();
                    switch (global.shared.init_state) {
                        .idle, .complete => unreachable,
                        .initializing => {},
                    }
                    global.shared.init_state = .complete;
                    lockedSendInitAck();
                }
            },
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

fn init() void {
    std.log.info("TODO: implement init", .{});
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");
