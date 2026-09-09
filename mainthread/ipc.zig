const global = struct {
    var state: State = .pending;
    var class_registered: bool = false;
};

const State = union(enum) {
    pending,
    ready: win32.HWND,
    failed,
};

pub fn ensureWindow() void {
    switch (global.state) {
        .pending => {},
        .ready, .failed => return,
    }

    var maybe_hinstance: ?win32.HINSTANCE = null;
    if (0 == win32.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(@intFromPtr(&wndProc)),
        &maybe_hinstance,
    )) {
        std.log.err("GetModuleHandleEx for the mutiny window failed, error={f}", .{win32.GetLastError()});
        global.state = .failed;
        return;
    }
    const hinstance = maybe_hinstance.?;

    if (!global.class_registered) {
        const wc: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = win32.L(mutinyipc.window_class_name),
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&wc)) switch (win32.GetLastError()) {
            .ERROR_CLASS_ALREADY_EXISTS => {},
            else => |e| {
                std.log.err("RegisterClassEx for the mutiny window failed, error={f}", .{e});
                global.state = .failed;
                return;
            },
        };
        global.class_registered = true;
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
        hinstance,
        null,
    ) orelse {
        std.log.err("CreateWindowEx for the mutiny window failed, error={f}", .{win32.GetLastError()});
        global.state = .failed;
        return;
    };
    std.log.info("mutiny window 0x{x} created on the main thread", .{@intFromPtr(hwnd)});
    global.state = .{ .ready = hwnd };
}

fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            // dont' call DefWindowProc, it destroys the window
            std.log.err("ignoring WM_CLOSE", .{});
            return 0;
        },
        win32.WM_COPYDATA => return onCopyData(wparam, lparam),
        mutinyipc.wm_heartbeat => return mutinyipc.heartbeat_result,
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn onCopyData(wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    const copy_data: *const win32.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (copy_data.dwData != mutinyipc.wm_copydata_run_script) {
        std.log.info("ignoring WM_COPYDATA with dwData 0x{x}", .{copy_data.dwData});
        return 0x7fffffff;
    }
    if (copy_data.cbData == 0 or copy_data.cbData % 2 != 0) {
        std.log.info("bad run-script cbData {}", .{copy_data.cbData});
        return 0x7fffffff;
    }
    const request_bytes = @as([*]const u8, @ptrCast(copy_data.lpData.?))[0..copy_data.cbData];
    const request: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, request_bytes));
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
}

fn reportError(
    writer: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) error{ WriteFailed, Reported } {
    writer.print(fmt ++ "\n", args) catch return error.WriteFailed;
    writer.flush() catch return error.WriteFailed;
    return error.Reported;
}

fn parseBuiltin(
    writer: *std.Io.Writer,
    builtin_name: []const u8,
    args: *mutinyipc.StringList,
) error{ Reported, WriteFailed }!Builtin {
    const builtin_script = std.meta.stringToEnum(
        Builtin,
        builtin_name[1..],
    ) orelse return reportError(writer, "unknown builtin script '{s}'", .{builtin_name});

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
        .{ builtin_name, arg_count },
    );
    return builtin_script;
}

fn addScript(
    pid: u32,
    pipe: win32.HANDLE,
    writer: *std.Io.Writer,
    name_w: []const u16,
    args: *mutinyipc.StringList,
) error{ Reported, WriteFailed }!void {
    const name_utf8_len = std.unicode.calcWtf8Len(name_w);
    if (name_utf8_len > ModNameSlice.max_len) return reportError(
        writer,
        "script name is {} bytes, too long (max {})",
        .{ name_utf8_len, ModNameSlice.max_len },
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

    var name_buf: [ModNameSlice.max_len]u8 = undefined;
    std.debug.assert(name_utf8_len == std.unicode.wtf16LeToWtf8(&name_buf, name_w));
    const name_a = name_buf[0..name_utf8_len];
    const script_name = ModNameSlice.init(name_a) orelse unreachable;

    if (name_w[0] == '@') {
        const builtin_script = try parseBuiltin(writer, name_a, args);
        return scripts.queue(pid, pipe, script_name, .{ .builtin = builtin_script }) catch reportError(
            writer,
            "out of memory creating script '{f}'",
            .{fmtW(name_w)},
        );
    }

    if (args.next() catch return reportError(
        writer,
        "malformed run-script arguments",
        .{},
    )) |_| return reportError(
        writer,
        "script '{s}' was given arguments but scripts do not take arguments yet",
        .{name_a},
    );

    io.requestLoad(pid, pipe, script_name) catch return reportError(
        writer,
        "out of memory requesting script '{f}'",
        .{fmtW(name_w)},
    );
}

const fmtW = std.unicode.fmtUtf16Le;

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");

const mainthread = @import("mainthread.zig");
const mutinyipc = mutiny.mutinyipc;
const scripts = @import("scripts.zig");
const io = @import("dll.io");

const Builtin = mainthread.Builtin;
const ModNameSlice = @import("ModNameSlice.zig");
