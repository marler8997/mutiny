const global = struct {
    var state: State = .{ .initial = .{} };
    var wnd_msg: u32 = undefined;
    var subclass: struct {
        mutex: std.Thread.Mutex = .{},
        wndproc: win32.WNDPROC = undefined,
    } = .{};
};

const State = union(enum) {
    initial: struct {
        register_error: ?win32.WIN32_ERROR = null,
    },
    find_window: struct {
        enum_windows_error: ?win32.WIN32_ERROR = null,
        candidate_count: ?u32 = null,
    },
    subclass: struct {
        hwnd: win32.HWND,
        tid: u32,
        set_wndproc_error: ?win32.WIN32_ERROR = null,
    },
    installed: struct {
        hwnd: win32.HWND,
        tid: u32,
    },
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
    @compileError("todo: implement eql for " ++ @typeName(T));
}

const PostActionArgs = if (builtin.os.tag == .windows) struct {
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
} else struct {};

pub const PostAction = union(enum) {
    subclass_self_test,
    pub fn deserialize(args: PostActionArgs) ?PostAction {
        if (builtin.os.tag == .windows) {
            return switch (args.wparam) {
                1 => return .subclass_self_test,
                else => null,
            };
        } else @panic("todo");
    }
    pub fn serialize(action: PostAction) PostActionArgs {
        if (builtin.os.tag == .windows) return switch (action) {
            .subclass_self_test => .{ .wparam = 1, .lparam = undefined },
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
pub fn getTarget() ?Target {
    return switch (global.state) {
        .initial,
        .find_window,
        .subclass,
        => null,
        .installed => |*state| .{ .data = .{ .hwnd = state.hwnd, .msg = global.wnd_msg } },
    };
}

// should be called by the mutiny thread
pub fn update() enum { not_newly_installed, newly_installed } {
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
                return .not_newly_installed;
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
                return .not_newly_installed;
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
                return .not_newly_installed;
            }
            const window = &ctx.first_candidate.?;
            std.log.info("found unity window 0x{x} on thread {}", .{ @intFromPtr(window.hwnd), window.tid });
            global.state = .{ .subclass = .{ .hwnd = window.hwnd, .tid = window.tid } };
            continue :state global.state;
        },
        .subclass => |*state| {
            const old_wndproc, const set_error = blk: {
                global.subclass.mutex.lock();
                defer global.subclass.mutex.unlock();
                win32.SetLastError(.NO_ERROR);
                const old_wndproc = win32.setWindowLongPtrW(
                    state.hwnd,
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
                return .not_newly_installed;
            }
            std.log.info("mainthread: subclassed window 0x{x} on thread {} (original wndproc 0x{x})", .{
                @intFromPtr(state.hwnd),
                state.tid,
                old_wndproc,
            });
            const hwnd = state.hwnd;
            const tid = state.tid;
            global.state = .{ .installed = .{ .hwnd = hwnd, .tid = tid } };
            return .newly_installed;
        },
        .installed => {},
    }
    return .not_newly_installed;
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

fn subclassProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == global.wnd_msg) {
        const action = PostAction.deserialize(.{ .wparam = wparam, .lparam = lparam }) orelse {
            std.log.err("unknown wparam 0x{x} lparam 0x{x}", .{ wparam, lparam });
            return 0;
        };
        switch (action) {
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

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
