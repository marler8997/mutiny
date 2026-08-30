const usage =
    \\Usage: mutiny COMMAND [ARGS...]
    \\
    \\Commands:
    \\  list                       Unity games running, their runtime, and whether Mutiny is in them
    \\  inject PID                 inject Mutiny.dll into a running game
    \\  start EXE [ARGS...]        launch a game with Mutiny.dll injected before it runs
    \\  run-script PID NAME        run scripts\SCRIPT in an injected game and print its output
    \\
;

pub fn main() !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    var args = try std.process.argsWithAllocator(arena);
    _ = args.skip(); // our own exe

    const command = args.next() orelse {
        try std.fs.File.stderr().writeAll(usage);
        return 0xff;
    };
    // if (std.mem.eql(u8, command, "list")) return cmdList(arena, &args);
    if (std.mem.eql(u8, command, "inject")) return cmdInject(arena, &args);
    if (std.mem.eql(u8, command, "start")) return cmdStart(arena, &args);
    // if (std.mem.eql(u8, command, "run-script")) return cmdRunScript(arena, &args);
    errExit("unknown command '{s}'", .{command});
}

// fn cmdList(arena: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
//     _ = arena;
//     noMoreArgs(args, "list");
//     errExit("todo: list", .{});
// }

fn cmdInject(arena: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
    var maybe_dll: ?[]const u8 = null;
    const pid_string = blk: {
        while (true) {
            const arg = args.next() orelse errExit("inject requires a PID (run 'mutiny list' to see what's running)", .{});
            if (!std.mem.startsWith(u8, arg, "-")) {
                break :blk arg;
            } else if (std.mem.eql(u8, arg, "--dll")) {
                maybe_dll = args.next() orelse errExit("--dll require an argument", .{});
            } else errExit("unknown cli option '{s}'", .{arg});
        }
    };
    const pid = std.fmt.parseInt(u32, pid_string, 10) catch errExit(
        "invalid pid '{s}'",
        .{pid_string},
    );
    noMoreArgs(args, "inject");
    const dll = maybe_dll orelse try findDll(arena);
    try injector.inject(arena, dll, pid);
    return 0;
}

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
    const dll = maybe_dll orelse try findDll(arena);
    if (args.next() != null) errExit("TODO: support extra start cmdline args to pass on to exe", .{});
    try injector.startExe(arena, dll, exe);
    return 0;
}

fn findDll(arena: std.mem.Allocator) ![]const u8 {
    const exe_dir = std.fs.selfExeDirPathAlloc(arena) catch |err| errExit(
        "unable to locate our own directory to find " ++ dll_name ++ " ({s})",
        .{@errorName(err)},
    );
    defer arena.free(exe_dir);
    const path = std.fs.path.resolve(
        arena,
        &.{ exe_dir, "..", "dll", dll_name },
    ) catch |e| oom(e);
    var path_owned = true;
    defer if (path_owned) arena.free(path);
    if (!try exists(path)) errExit(
        "no " ++ dll_name ++ " at '{s}' (pass --dll to point at it)",
        .{path},
    );
    std.log.info("found dll at '{s}'", .{path});
    path_owned = false;
    return path;
}

const dll_name = "Mutiny.dll";

fn exists(path: []const u8) !bool {
    return if (std.fs.cwd().access(path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| e,
    };
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
const injector = @import("injector.zig");
