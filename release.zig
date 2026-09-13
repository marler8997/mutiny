const branch = "master";
const installer = "zig-out\\MutinySetup.exe";

pub fn main() !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 3) {
        std.log.err("usage: release ZIG_EXE REPO_ROOT [--dry-run]", .{});
        return 0xff;
    }
    const zig_exe = args[1];
    const root = args[2];
    var dry_run = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            std.log.err("unknown argument '{s}'", .{arg});
            return 0xff;
        }
    }

    const status = try run(arena, root, &.{ "git", "status", "--porcelain", "--untracked-files=no" });
    if (status.len != 0) {
        std.log.err("the working tree has uncommitted changes:\n{s}", .{status});
        return 0xff;
    }
    const sha = try run(arena, root, &.{ "git", "rev-parse", "HEAD" });
    const short = try run(arena, root, &.{ "git", "rev-parse", "--short", "HEAD" });

    _ = try run(arena, root, &.{ "git", "fetch", "origin", branch });
    {
        const result = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "git", "merge-base", "--is-ancestor", sha, "origin/" ++ branch },
            .cwd = root,
        }) catch |err| {
            std.log.err("running git failed with {t}", .{err});
            return 0xff;
        };
        switch (result.term) {
            .Exited => |code| switch (code) {
                0 => {},
                1 => {
                    std.log.err("commit {s} is not on origin/{s}, push it there first", .{ short, branch });
                    return 0xff;
                },
                else => {
                    std.log.err("git merge-base exited with {}:\n{s}", .{ code, result.stderr });
                    return 0xff;
                },
            },
            else => {
                std.log.err("git merge-base did not exit normally", .{});
                return 0xff;
            },
        }
    }

    const tag = try std.fmt.allocPrint(arena, "release-{s}", .{short});
    if (std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "gh", "release", "view", tag, "--json", "url", "--jq", ".url" },
        .cwd = root,
    })) |result| switch (result.term) {
        .Exited => |code| if (code == 0) {
            std.log.info("{s} is already released: {s}", .{ short, std.mem.trim(u8, result.stdout, &std.ascii.whitespace) });
            return 0;
        },
        else => {},
    } else |err| {
        std.log.err("running gh failed with {t}, is the GitHub CLI installed and logged in?", .{err});
        return 0xff;
    }

    std.log.info("building the installer for {s}", .{short});
    try runInherit(arena, root, &.{ zig_exe, "build", "installer", "-Doptimize=ReleaseSafe" });

    const title = try std.fmt.allocPrint(arena, "Mutiny {s}", .{short});
    const notes = try std.fmt.allocPrint(arena, "Built from {s}.", .{sha});
    const create = [_][]const u8{
        "gh",      "release",  "create", tag,
        installer, "--target", sha,      "--title",
        title,     "--notes",  notes,    "--latest",
    };
    if (dry_run) {
        std.log.info("dry run, would run: {s}", .{try std.mem.join(arena, " ", &create)});
        return 0;
    }
    try runInherit(arena, root, &create);
    const url = try run(arena, root, &.{ "gh", "release", "view", tag, "--json", "url", "--jq", ".url" });
    std.log.info("released {s}: {s}", .{ short, url });
    return 0;
}

fn run(arena: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]const u8 {
    const result = std.process.Child.run(.{ .allocator = arena, .argv = argv, .cwd = cwd }) catch |err| {
        std.log.err("running '{s}' failed with {t}", .{ argv[0], err });
        return error.Reported;
    };
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.log.err("'{s}' exited with {}:\n{s}{s}", .{ try std.mem.join(arena, " ", argv), code, result.stdout, result.stderr });
            return error.Reported;
        },
        else => {
            std.log.err("'{s}' did not exit normally", .{argv[0]});
            return error.Reported;
        },
    }
    return std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
}

fn runInherit(arena: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, arena);
    child.cwd = cwd;
    const term = child.spawnAndWait() catch |err| {
        std.log.err("running '{s}' failed with {t}", .{ argv[0], err });
        return error.Reported;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.log.err("'{s}' exited with {}", .{ try std.mem.join(arena, " ", argv), code });
            return error.Reported;
        },
        else => {
            std.log.err("'{s}' did not exit normally", .{argv[0]});
            return error.Reported;
        },
    }
}

const std = @import("std");
