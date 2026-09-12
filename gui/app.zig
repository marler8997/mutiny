pub const title = "Mutiny";
pub const initial_client_points: layout.XY = .{ .x = 640, .y = 420 };

const Games = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    err: ?LoadError = null,

    const LoadError = struct {
        what: []const u8,
        name: []const u8,
    };

    fn slice(games: *const Games) []const []const u8 {
        return games.names.items;
    }
};

const global = struct {
    var apps_dir: std.fs.Dir = undefined;
    var games: Games = .{};
    var mouse: ?layout.XY = null;
};

pub fn init(apps_dir: std.fs.Dir) void {
    global.apps_dir = apps_dir;
    loadGames();
}

pub fn onAppsDirChanged() void {
    loadGames();
    platform.invalidate();
}

pub fn onMouse(position: ?layout.XY) void {
    global.mouse = position;
    platform.invalidate();
}

fn loadGames() void {
    const games = &global.games;
    games.names.clearRetainingCapacity();
    _ = games.arena.reset(.retain_capacity);
    games.err = null;
    const allocator = games.arena.allocator();

    var it = global.apps_dir.iterate();
    while (it.next() catch |e| {
        games.err = .{ .what = "list app directory failed", .name = @errorName(e) };
        return;
    }) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > layout.max_game_name) {
            std.log.warn("app directory name is {} bytes, ignoring it (max {})", .{ entry.name.len, layout.max_game_name });
            continue;
        }
        if (!hasExePath(entry.name)) continue;
        const name = allocator.dupe(u8, entry.name) catch |e| {
            games.err = .{ .what = "out of memory listing games", .name = @errorName(e) };
            return;
        };
        games.names.append(allocator, name) catch |e| {
            games.err = .{ .what = "out of memory listing games", .name = @errorName(e) };
            return;
        };
    }
    std.mem.sort([]const u8, games.names.items, {}, nameLessThan);
}

fn hasExePath(name: []const u8) bool {
    var path_buf: [layout.max_game_name + 1 + "exepath".len]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{c}exepath", .{ name, std.fs.path.sep }) catch unreachable;
    global.apps_dir.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            std.log.warn("cannot check '{s}': {t}, ignoring it", .{ path, err });
            return false;
        },
    };
    return true;
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

pub fn onPaint(p: *const platform.Painter, client: layout.XY, scale: f32) void {
    p.fill(.{ .left = 0, .top = 0, .right = client.x, .bottom = client.y }, layout.color.window);
    const grid: layout.Grid = .init(client, scale);
    const games = &global.games;

    if (games.err) |err| {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ err.what, err.name }) catch err.what;
        p.text(text, grid.textLine(grid.origin, 0), layout.color.text);
        return;
    }
    if (games.slice().len == 0) {
        p.text(layout.empty_title, grid.textLine(grid.origin, 0), layout.color.text);
        p.text(layout.empty_body, grid.textLine(grid.origin, 1), layout.color.muted);
        return;
    }

    for (games.slice()[0..@min(games.slice().len, grid.visible())], 0..) |name, index| {
        const tile = grid.tileRect(index);
        const hovered = if (global.mouse) |m| tile.contains(m) else false;
        p.fill(tile, layout.color.tile_edge);
        p.fill(tile.inset(1), if (hovered) layout.color.tile_hover else layout.color.tile);
        p.fill(grid.iconRect(tile), layout.color.icon);
        p.text(name, grid.nameRect(tile), layout.color.name);
    }
}

const std = @import("std");

const layout = @import("layout.zig");
const platform = @import("root");
