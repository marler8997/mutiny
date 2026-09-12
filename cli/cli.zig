const usage =
    \\Usage:
    \\  mutiny scan                  every running Unity game (by its window), and whether Mutiny is attached.
    \\  mutiny start EXE [ARGS...]   launch a game with Mutiny.dll injected before it runs.
    \\
    \\  mutiny PID attach            get Mutiny running inside an already-running game.
    \\  mutiny PID run-script NAME   run scripts\NAME in an injected game and print its output
    \\                               an @-prefixed NAME is a builtin, e.g. @assemblies.
    \\  mutiny PID enable-mod NAME   turn mods\NAME on or off, the same as its checkbox in
    \\  mutiny PID disable-mod NAME  the in-game panel; a disabled mod runs its .disable section
    \\
;

pub fn main() !u8 {
    return run() catch |err| switch (err) {
        error.Reported => 0xff,
        else => |e| e,
    };
}

fn run() !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    var args = try std.process.argsWithAllocator(arena);
    _ = args.skip(); // our own exe

    const command = args.next() orelse {
        try std.fs.File.stderr().writeAll(usage);
        return 0xff;
    };

    // Process-targeted commands are "mutiny PID VERB ..." so the PID - the tedious part - stays
    // at the front and the verb can be swapped by editing the tail. A token that parses as a u32
    // is a PID (the next token is its verb); anything else is a global command. Commands are
    // alphabetic, so the two can't collide.
    if (std.fmt.parseInt(u32, command, 10)) |pid| {
        const verb = args.next() orelse errExit(
            "expected a command after pid {} (attach, run-script, enable-mod, disable-mod)",
            .{pid},
        );
        if (std.mem.eql(u8, verb, "attach")) return cmdAttach(arena, &args, pid);
        if (std.mem.eql(u8, verb, "run-script")) return cmdRunScript(arena, &args, pid);
        if (std.mem.eql(u8, verb, "enable-mod")) return cmdSetModEnabled(arena, &args, pid, true);
        if (std.mem.eql(u8, verb, "disable-mod")) return cmdSetModEnabled(arena, &args, pid, false);
        errExit("unknown command '{s}' for pid {} (attach, run-script, enable-mod, disable-mod)", .{ verb, pid });
    } else |_| {}

    if (std.mem.eql(u8, command, "scan")) return cmdScan(arena, &args);
    if (std.mem.eql(u8, command, "start")) return cmdStart(arena, &args);
    errExit("unknown command '{s}' (expected scan, start, or a PID)", .{command});
}

fn cmdScan(arena: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
    noMoreArgs(args, "scan");
    return try cliscan.go(arena);
}

fn cmdAttach(arena: std.mem.Allocator, args: *std.process.ArgIterator, pid: u32) !u8 {
    var maybe_dll: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dll")) {
            maybe_dll = args.next() orelse errExit("--dll requires an argument", .{});
        } else errExit("unknown cli option '{s}'", .{arg});
    }
    const dll = maybe_dll orelse try injector.findDll(arena, dll_relative_dir);
    try injector.attach(arena, dll, pid);
    return 0;
}

const dll_relative_dir = "..\\dll";

fn cmdStart(arena: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
    var maybe_dll: ?[]const u8 = null;
    const exe = blk: {
        while (true) {
            const arg = args.next() orelse errExit("start requires a path to a game exe", .{});
            if (!std.mem.startsWith(u8, arg, "-")) {
                break :blk arg;
            } else if (std.mem.eql(u8, arg, "--dll")) {
                maybe_dll = args.next() orelse errExit("--dll require an argument", .{});
            } else errExit("unknown cli option '{s}'", .{arg});
        }
    };
    const dll = maybe_dll orelse try injector.findDll(arena, dll_relative_dir);
    if (args.next() != null) errExit("TODO: support extra start cmdline args to pass on to exe", .{});
    try injector.startExe(arena, dll, exe);
    return 0;
}

fn cmdRunScript(arena: std.mem.Allocator, args: *std.process.ArgIterator, pid: u32) !u8 {
    const script = args.next() orelse errExit("run-script requires a script name", .{});
    if (std.mem.indexOfAny(u8, script, "\\/:") != null) errExit(
        "'{s}' looks like a path, pass just the name of a file in the scripts directory",
        .{script},
    );

    const hwnd = mutinyipc.findWindow(pid) orelse errExit(
        "pid {} has no mutiny window (is Mutiny.dll injected?)",
        .{pid},
    );

    var pipe_name_buf: [mutinyipc.pipe_name_buf_len]u16 = undefined;
    const pipe_name = mutinyipc.formatClientPipeName(&pipe_name_buf, win32.GetCurrentProcessId());
    const pipe = win32.CreateNamedPipeW(
        pipe_name,
        win32.PIPE_ACCESS_INBOUND,
        .{},
        1,
        0,
        4096,
        0,
        null,
    );
    if (pipe == win32.INVALID_HANDLE_VALUE) errExit(
        "CreateNamedPipe '{f}' failed, error={f}",
        .{ std.unicode.fmtUtf16Le(pipe_name), win32.GetLastError() },
    );
    defer win32.closeHandle(pipe);

    const request = blk: {
        var size_args = args.*;
        var count: usize = 1;
        var len: usize = 1 + 1 + wtf16Len(script);
        while (size_args.next()) |arg| {
            count += 1;
            len += 1 + wtf16Len(arg);
        }
        if (count > std.math.maxInt(u16)) errExit("too many arguments ({})", .{count});

        const buf = arena.alloc(u16, len) catch |e| oom(e);
        buf[0] = @intCast(count);
        var offset: usize = 1;
        offset += writeString(buf[offset..], script);
        while (args.next()) |arg| offset += writeString(buf[offset..], arg);
        std.debug.assert(offset == len);
        break :blk buf;
    };

    const copy_data: win32.COPYDATASTRUCT = .{
        .dwData = mutinyipc.wm_copydata_run_script,
        .cbData = @intCast(request.len * 2),
        .lpData = @ptrCast(request.ptr),
    };
    const result = win32.SendMessageW(
        hwnd,
        win32.WM_COPYDATA,
        win32.GetCurrentProcessId(),
        @bitCast(@intFromPtr(&copy_data)),
    );
    if (result != mutinyipc.wm_copydata_result) errExit(
        "pid {} did not handle the request (returned {}), is it running a compatible Mutiny.dll?",
        .{ pid, result },
    );

    const stdout = std.fs.File.stdout().handle;
    while (true) {
        var buf: [4096]u8 = undefined;
        var read_len: u32 = undefined;
        if (0 == win32.ReadFile(pipe, &buf, buf.len, &read_len, null)) switch (win32.GetLastError()) {
            .ERROR_BROKEN_PIPE => break,
            else => |e| errExit("read from pid {} failed, error={f}", .{ pid, e }),
        };
        if (read_len == 0) break;
        var written: u32 = 0;
        while (written < read_len) {
            var wrote: u32 = undefined;
            if (0 == win32.WriteFile(
                stdout,
                buf[written..].ptr,
                read_len - written,
                &wrote,
                null,
            )) win32.panicWin32("WriteFile(stdout)", win32.GetLastError());
            written += wrote;
        }
    }
    return 0;
}

fn cmdSetModEnabled(arena: std.mem.Allocator, args: *std.process.ArgIterator, pid: u32, enabled: bool) !u8 {
    const verb = if (enabled) "enable-mod" else "disable-mod";
    const name = args.next() orelse errExit("{s} requires a mod name", .{verb});
    noMoreArgs(args, verb);
    if (std.mem.indexOfAny(u8, name, "\\/:") != null) errExit(
        "'{s}' looks like a path, pass just the name of a file in the mods directory",
        .{name},
    );

    const hwnd = mutinyipc.findWindow(pid) orelse errExit(
        "pid {} has no mutiny window (is Mutiny.dll injected?)",
        .{pid},
    );

    const request = arena.alloc(u16, 1 + 1 + wtf16Len(name)) catch |e| oom(e);
    request[0] = 1;
    std.debug.assert(1 + writeString(request[1..], name) == request.len);

    const copy_data: win32.COPYDATASTRUCT = .{
        .dwData = mutinyipc.wm_copydata_set_mod_enabled,
        .cbData = @intCast(request.len * 2),
        .lpData = @ptrCast(request.ptr),
    };
    const result = win32.SendMessageW(
        hwnd,
        win32.WM_COPYDATA,
        @intFromBool(enabled),
        @bitCast(@intFromPtr(&copy_data)),
    );
    const word = if (enabled) "enabled" else "disabled";
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    switch (@as(mutinyipc.SetModEnabledResult, @enumFromInt(result))) {
        .changed => stdout.print("mod '{s}' {s}\n", .{ name, word }) catch return stdout_writer.err.?,
        .unchanged => stdout.print("mod '{s}' was already {s}\n", .{ name, word }) catch return stdout_writer.err.?,
        .no_such_mod => errExit("pid {} has no mod named '{s}'", .{ pid, name }),
        _ => errExit(
            "pid {} did not handle the request (returned {}), is it running a compatible Mutiny.dll?",
            .{ pid, result },
        ),
    }
    stdout.flush() catch return stdout_writer.err.?;
    return 0;
}

fn wtf16Len(utf8: []const u8) usize {
    return std.unicode.calcWtf16LeLen(utf8) catch errExit(
        "'{s}' is not valid UTF-8",
        .{utf8},
    );
}

fn wtf16Encode(buf: []u16, utf8: []const u8) usize {
    return std.unicode.wtf8ToWtf16Le(buf, utf8) catch errExit(
        "'{s}' is not valid UTF-8",
        .{utf8},
    );
}

fn writeString(buf: []u16, utf8: []const u8) usize {
    const len = wtf16Len(utf8);
    if (len > mutinyipc.max_string_len) errExit(
        "'{s}' is {} characters, too long (max {})",
        .{ utf8, len, mutinyipc.max_string_len },
    );
    buf[0] = @intCast(len);
    std.debug.assert(len == wtf16Encode(buf[1..], utf8));
    return 1 + len;
}

fn noMoreArgs(args: *std.process.ArgIterator, command: []const u8) void {
    if (args.next()) |extra| errExit(
        "unexpected argument '{s}' after the {s} command",
        .{ extra, command },
    );
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");
const mutinyipc = mutiny.mutinyipc;

const cliscan = @import("cliscan.zig");
const injector = mutiny.injector;
