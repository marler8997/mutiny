pub fn main() !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var args = try std.process.argsWithAllocator(arena);
    _ = args.skip();
    const source = args.next() orelse errExit("installappdata requires a source directory", .{});
    if (args.next()) |extra| errExit("unexpected argument '{s}'", .{extra});

    const localappdata_w = appdata.get() orelse errExit("no LOCALAPPDATA environment variable", .{});
    const localappdata = std.unicode.wtf16LeToWtf8Alloc(arena, localappdata_w) catch |e| oom(e);
    const dest = std.fs.path.join(arena, &.{ localappdata, "mutiny" }) catch |e| oom(e);

    var buf: [4096]u8 = undefined;
    var file_writer = std.fs.File.stdout().writer(&buf);
    const failures = install(&file_writer.interface, arena, source, dest) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
    };
    return if (failures == 0) 0 else 0xff;
}

const Status = enum {
    @"up-to-date",
    updated,
    new,
};

fn install(
    writer: *std.Io.Writer,
    arena: std.mem.Allocator,
    source: []const u8,
    dest: []const u8,
) error{WriteFailed}!u32 {
    try writer.print("installing '{s}'\n        to '{s}'\n\n", .{ source, dest });

    var source_dir = std.fs.cwd().openDir(source, .{ .iterate = true }) catch |err| errExit(
        "open source directory '{s}' failed with {t}",
        .{ source, err },
    );
    defer source_dir.close();

    std.fs.cwd().makePath(dest) catch |err| errExit(
        "create '{s}' failed with {t}",
        .{ dest, err },
    );
    var dest_dir = std.fs.cwd().openDir(dest, .{}) catch |err| errExit(
        "open destination directory '{s}' failed with {t}",
        .{ dest, err },
    );
    defer dest_dir.close();

    var counts: std.EnumArray(Status, u32) = .initFill(0);
    var failures: u32 = 0;

    var walker = source_dir.walk(arena) catch |e| oom(e);
    defer walker.deinit();
    while (walker.next() catch |err| errExit(
        "walk '{s}' failed with {t}",
        .{ source, err },
    )) |entry| {
        if (entry.kind != .file) continue;
        if (installFile(source_dir, dest_dir, entry.path)) |status| {
            counts.getPtr(status).* += 1;
            try writer.print("  {t: <11} {s}\n", .{ status, entry.path });
        } else |err| {
            failures += 1;
            try writer.print("  {s: <11} {s} ({t})\n", .{ "FAILED", entry.path, err });
        }
    }

    const total = counts.get(.new) + counts.get(.updated) + counts.get(.@"up-to-date") + failures;
    try writer.print("\n{} file(s): {} new, {} updated, {} already up-to-date", .{
        total,
        counts.get(.new),
        counts.get(.updated),
        counts.get(.@"up-to-date"),
    });
    if (failures == 0) {
        try writer.writeAll("\n");
    } else {
        try writer.print(", {} FAILED\n", .{failures});
    }
    try writer.flush();
    return failures;
}

fn installFile(
    source_dir: std.fs.Dir,
    dest_dir: std.fs.Dir,
    path: []const u8,
) !Status {
    const status: Status = blk: {
        var source_file = try source_dir.openFile(path, .{});
        defer source_file.close();
        var dest_file = dest_dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk .new,
            else => |e| return e,
        };
        defer dest_file.close();
        if (try sameContent(source_file, dest_file)) return .@"up-to-date";
        break :blk .updated;
    };

    if (std.fs.path.dirname(path)) |sub_dir| try dest_dir.makePath(sub_dir);
    try source_dir.copyFile(path, dest_dir, path, .{});
    return status;
}

fn sameContent(a: std.fs.File, b: std.fs.File) !bool {
    if (try a.getEndPos() != try b.getEndPos()) return false;
    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    while (true) {
        const a_len = try a.readAll(&a_buf);
        const b_len = try b.readAll(&b_buf);
        if (a_len != b_len) return false;
        if (a_len == 0) return true;
        if (!std.mem.eql(u8, a_buf[0..a_len], b_buf[0..b_len])) return false;
    }
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const appdata = @import("appdata.zig");
