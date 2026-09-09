const global = struct {
    var active_thread_id: u32 = 0;
    var mutex: std.atomic.Value(?win32.HANDLE) = .init(null);
};

pub fn activeThreadId() u32 {
    return global.active_thread_id;
}

comptime {
    @export(&MutinyAttach, .{ .name = mutinyipc.attach_export_name });
}
fn MutinyAttach(context: ?*anyopaque) callconv(.winapi) u32 {
    const timeout: Timeout = .{ .start = win32.GetTickCount64(), .ms = @intCast(@intFromPtr(context)) };
    std.log.info("MutinyAttach (timeout {} ms)", .{timeout.ms});
    var maybe_module: ?win32.HINSTANCE = null;
    if (0 != win32.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(@intFromPtr(&MutinyAttach)),
        &maybe_module,
    )) {
        std.log.info("module \"Mutiny.dll\" at 0x{x}", .{@intFromPtr(maybe_module.?)});
    }

    const mutex = claimMutex(timeout.remaining()) orelse return mutinyipc.AttachResult.fail;
    defer if (0 == win32.ReleaseMutex(mutex)) win32.panicWin32("ReleaseMutex", win32.GetLastError());

    global.active_thread_id = win32.GetCurrentThreadId();
    defer global.active_thread_id = 0;

    var state: dll_main.AttachState = .{};
    while (true) switch (state.update()) {
        .attached => {
            std.log.info("attached", .{});
            return mutinyipc.AttachResult.success;
        },
        .failed => return mutinyipc.AttachResult.fail,
        .retry_ms => |ms| {
            const remaining = timeout.remaining();
            if (remaining == 0) {
                std.log.err("attach timed out after {} ms in the {t} stage", .{ timeout.ms, state.stage });
                return mutinyipc.AttachResult.fail;
            }
            win32.Sleep(@min(ms, remaining));
        },
    };
}

const Timeout = struct {
    start: u64,
    ms: u32,

    fn remaining(timeout: Timeout) u32 {
        const elapsed = win32.GetTickCount64() - timeout.start;
        return @intCast(timeout.ms -| @min(elapsed, std.math.maxInt(u32)));
    }
};

fn attachMutex() ?win32.HANDLE {
    if (global.mutex.load(.acquire)) |mutex| return mutex;
    const created = win32.CreateMutexW(null, 0, null) orelse {
        std.log.err("CreateMutex failed, error={f}", .{win32.GetLastError()});
        return null;
    };
    if (global.mutex.cmpxchgStrong(null, created, .acq_rel, .acquire)) |winner| {
        win32.closeHandle(created);
        return winner;
    }
    return created;
}

fn claimMutex(timeout_ms: u32) ?win32.HANDLE {
    const mutex = attachMutex() orelse return null;
    switch (win32.WaitForSingleObject(mutex, timeout_ms)) {
        @intFromEnum(win32.WAIT_OBJECT_0) => {},
        @intFromEnum(win32.WAIT_ABANDONED) => std.log.info("the previous attach thread died holding the mutex, taking over", .{}),
        @intFromEnum(win32.WAIT_TIMEOUT) => {
            std.log.err("another attach is still in progress after {} ms", .{timeout_ms});
            return null;
        },
        @intFromEnum(win32.WAIT_FAILED) => {
            std.log.err("wait on the attach mutex failed, error={f}", .{win32.GetLastError()});
            return null;
        },
        else => |result| std.debug.panic("WaitForSingleObject returned {d}", .{result}),
    }
    return mutex;
}

const std = @import("std");
const win32 = @import("win32").everything;
const dll_main = @import("dll_main");

const mutinyipc = dll_main.mutinyipc;
