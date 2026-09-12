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
    var scroll: i32 = 0;
    var drag: ?struct { start_y: i32, start_scroll: i32 } = null;
    var client: layout.XY = .{ .x = 0, .y = 0 };
    var scale: f32 = 1;
};

fn grid() layout.Grid {
    return .init(global.client, global.scale, global.games.slice().len, global.scroll);
}

fn scrollTo(scroll: i32) void {
    const clamped = grid().clampScroll(scroll);
    if (clamped == global.scroll) return;
    global.scroll = clamped;
    platform.invalidate();
}

fn scrollBy(pixels: i32) void {
    scrollTo(global.scroll +| pixels);
}

pub fn onWheel(notches: f32) void {
    scrollBy(-layout.scale(grid().rowPitch(), notches));
}

pub fn onKey(key: layout.Key) void {
    const g = grid();
    switch (key) {
        .up => scrollBy(-g.rowPitch()),
        .down => scrollBy(g.rowPitch()),
        .page_up => scrollBy(-g.viewportHeight()),
        .page_down => scrollBy(g.viewportHeight()),
        .home => scrollTo(0),
        .end => scrollTo(g.maxScroll()),
    }
}

pub fn onMouseButton(button: layout.MouseButton, state: layout.ButtonState, position: layout.XY) void {
    _ = button;
    global.mouse = position;
    switch (state) {
        .down => {
            if (grid().thumbRect()) |thumb| if (thumb.contains(position)) {
                global.drag = .{ .start_y = position.y, .start_scroll = global.scroll };
                platform.captureMouse(true);
            };
        },
        .up => {
            if (global.drag != null) {
                global.drag = null;
                platform.captureMouse(false);
            }
        },
    }
    platform.invalidate();
}

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
    if (global.drag) |drag| if (position) |p| {
        scrollTo(grid().scrollFromDrag(drag.start_scroll, p.y - drag.start_y));
    };
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
    global.client = client;
    global.scale = scale;
    p.fill(.{ .left = 0, .top = 0, .right = client.x, .bottom = client.y }, layout.color.window);
    const g = grid();
    global.scroll = g.scroll;
    const games = &global.games;

    if (games.err) |err| {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ err.what, err.name }) catch err.what;
        p.text(text, g.textLine(0), layout.color.text);
        return;
    }
    if (games.slice().len == 0) {
        p.text(layout.empty_title, g.textLine(0), layout.color.text);
        p.text(layout.empty_body, g.textLine(1), layout.color.muted);
        return;
    }

    const hovered_tile = if (global.mouse) |m| g.hitTile(m) else null;
    const range = g.visibleRange();
    p.pushClip(g.viewport);
    for (games.slice()[range.first..range.end], range.first..) |name, index| {
        const tile = g.tileRect(index);
        p.fill(tile, layout.color.tile_edge);
        p.fill(tile.inset(1), if (hovered_tile == index) layout.color.tile_hover else layout.color.tile);
        p.fill(g.iconRect(tile), layout.color.icon);
        p.text(name, g.nameRect(tile), layout.color.name);
    }
    p.popClip();

    if (g.scrollbar) |track| {
        p.fill(track, layout.color.track);
        const thumb = g.thumbRect().?;
        const hot = global.drag != null or (if (global.mouse) |m| thumb.contains(m) else false);
        p.fill(thumb, if (hot) layout.color.thumb_hover else layout.color.thumb);
    }
}

const std = @import("std");

const layout = @import("layout.zig");
const platform = @import("root");
