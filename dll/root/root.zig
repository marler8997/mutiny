pub const enable_mutiny_test_class = false;

const global = struct {
    var paniced_threads_logging: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_dumping: std.atomic.Value(u32) = .{ .raw = 0 };
    var paniced_threads_msgboxing: std.atomic.Value(u32) = .{ .raw = 0 };
};

fn isOurThread(thread_id: u32) bool {
    return thread_id == attach.activeThreadId() or thread_id == mainthread.ioThreadId();
}

comptime {
    _ = attach;
}

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    const current_thread_id = win32.GetCurrentThreadId();
    if (0 == global.paniced_threads_logging.fetchAdd(1, .seq_cst)) {
        std.log.err("panic: {s}", .{msg});
    }
    if (0 == global.paniced_threads_dumping.fetchAdd(1, .seq_cst)) {
        const log_file, const maybe_open_log_error = logfile.global.get();
        _ = maybe_open_log_error;
        // no buffer so we flush as soon as possible so as not to lose any output
        var file_writer = log_file.writer(&.{});
        const trace_result = if (isOurThread(current_thread_id)) writeStackTrace(
            error_return_trace,
            ret_addr,
            std.io.tty.detectConfig(log_file),
            &file_writer.interface,
        ) else writeRawStackTrace(&file_writer.interface);
        trace_result catch |err| file_writer.interface.print(
            "write stack trace failed with {t}\n",
            .{switch (err) {
                error.WriteFailed => file_writer.err orelse error.Unexpected,
                else => |e| e,
            }},
        ) catch {};
    }
    if (isOurThread(current_thread_id)) {
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
        "panic on thread {} (not one of ours), raising an exception for the game's crash handler",
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

fn writeRawStackTrace(writer: *std.Io.Writer) !void {
    var frames: [64]?*anyopaque = undefined;
    const count = win32.RtlCaptureStackBackTrace(1, frames.len, &frames, null);
    try writer.print("stack trace ({} frames, module+offset):\n", .{count});
    for (frames[0..count]) |frame| {
        const addr = @intFromPtr(frame);
        var module: ?win32.HINSTANCE = null;
        if (0 != win32.GetModuleHandleExW(
            win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            @ptrFromInt(addr),
            &module,
        )) {
            var path: [win32.MAX_PATH:0]u16 = undefined;
            const len = win32.GetModuleFileNameW(module, &path, path.len);
            const name = path[0..len];
            var basename_start: usize = 0;
            for (name, 0..) |c, i| if (c == '\\' or c == '/') {
                basename_start = i + 1;
            };
            try writer.print("  {f}+0x{x}\n", .{
                std.unicode.fmtUtf16Le(name[basename_start..]),
                addr - @intFromPtr(module.?),
            });
        } else {
            try writer.print("  0x{x}\n", .{addr});
        }
    }
    try writer.flush();
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

pub const mutiny_options: mainthread.Options = .{
    .onUpdate = mainthread.onUpdate,
    .onGui = mainthread.onGui,
};

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

const fmtW = std.unicode.fmtUtf16Le;

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const mainthread = @import("mainthread");
const attach = @import("dll.attach");

const logfile = mainthread.logfile;
