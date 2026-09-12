pub const title = "Mutiny";
pub const initial_client_points: layout.XY = .{ .x = 640, .y = 420 };

pub const Status = enum { not_attached, attached, unresponsive };

pub const Running = struct {
    pid: u32,
    name: []const u8,
    status: Status,
};

const Game = struct {
    name: []const u8,
    running: ?Running,
    attach: enum { idle, attaching, failed } = .idle,

    fn button(game: *const Game) layout.Button {
        const running = game.running orelse return .launch;
        return switch (game.attach) {
            .attaching => .attaching,
            .failed => .attach_failed,
            .idle => switch (running.status) {
                .not_attached => .attach,
                .attached => .attached,
                .unresponsive => .not_responding,
            },
        };
    }
};

const Games = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    list: std.ArrayListUnmanaged(Game) = .empty,
    err: ?LoadError = null,

    const LoadError = struct {
        what: []const u8,
        name: []const u8,
    };

    fn slice(games: *const Games) []Game {
        return games.list.items;
    }
};

const global = struct {
    var apps_dir: std.fs.Dir = undefined;
    var games: Games = .{};
    var running_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var running: []const Running = &.{};
    var mouse: ?layout.XY = null;
    var scroll: i32 = 0;
    var drag: ?struct { start_y: i32, start_scroll: i32 } = null;
    var client: layout.XY = .{ .x = 0, .y = 0 };
    var scale: f32 = 1;
};

pub fn init(apps_dir: std.fs.Dir) void {
    global.apps_dir = apps_dir;
    rescan();
    loadGames();
}

pub fn onAppsDirChanged() void {
    loadGames();
    platform.invalidate();
}

pub fn onAttachDone(pid: u32, success: bool) void {
    rescan();
    for (global.games.slice()) |*game| {
        const running = game.running orelse continue;
        if (running.pid != pid) continue;
        game.attach = if (success) .idle else .failed;
    }
    platform.invalidate();
}

fn rescan() void {
    _ = global.running_arena.reset(.retain_capacity);
    global.running = platform.runningGames(global.running_arena.allocator()) catch |err| blk: {
        std.log.err("scan for running games failed: {t}", .{err});
        break :blk &.{};
    };
    for (global.games.slice()) |*game| game.running = runningFor(game.name);
}

fn runningFor(name: []const u8) ?Running {
    for (global.running) |running| {
        if (std.ascii.eqlIgnoreCase(running.name, name)) return running;
    }
    return null;
}

pub fn onMouse(position: ?layout.XY) void {
    global.mouse = position;
    if (global.drag) |drag| if (position) |p| {
        scrollTo(grid().scrollFromDrag(drag.start_scroll, p.y - drag.start_y));
    };
    platform.invalidate();
}

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
    const g = grid();
    switch (state) {
        .down => {
            if (g.thumbRect()) |thumb| if (thumb.contains(position)) {
                global.drag = .{ .start_y = position.y, .start_scroll = global.scroll };
                platform.captureMouse(true);
            };
        },
        .up => {
            if (global.drag != null) {
                global.drag = null;
                platform.captureMouse(false);
            } else if (g.hitTile(position)) |index| {
                const game = &global.games.slice()[index];
                if (g.buttonRect(g.tileRect(index)).contains(position)) clickButton(game);
            }
        },
    }
    platform.invalidate();
}

fn clickButton(game: *Game) void {
    switch (game.button()) {
        .launch => std.log.info("launch '{s}': not implemented yet", .{game.name}),
        .attach, .attach_failed => {
            const running = game.running orelse return;
            game.attach = .attaching;
            platform.attach(running.pid);
        },
        else => {},
    }
}

fn loadGames() void {
    const games = &global.games;
    _ = games.arena.reset(.retain_capacity);
    games.list = .empty;
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
        games.list.append(allocator, .{ .name = name, .running = runningFor(name) }) catch |e| {
            games.err = .{ .what = "out of memory listing games", .name = @errorName(e) };
            return;
        };
    }
    std.mem.sort(Game, games.list.items, {}, gameLessThan);
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

fn gameLessThan(_: void, a: Game, b: Game) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
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
        p.text(text, g.textLine(0), layout.color.text, .left);
        return;
    }
    if (games.slice().len == 0) {
        p.text(layout.empty_title, g.textLine(0), layout.color.text, .left);
        p.text(layout.empty_body, g.textLine(1), layout.color.muted, .left);
        return;
    }

    const hovered_tile = if (global.mouse) |m| g.hitTile(m) else null;
    const range = g.visibleRange();
    p.pushClip(g.viewport);
    for (games.slice()[range.first..range.end], range.first..) |*game, index| {
        const tile = g.tileRect(index);
        p.fill(tile, layout.color.tile_edge);
        p.fill(tile.inset(1), if (hovered_tile == index) layout.color.tile_hover else layout.color.tile);
        p.fill(g.iconRect(tile), layout.color.icon);
        p.text(game.name, g.nameRect(tile), layout.color.name, .left);
        if (game.running) |running| {
            var buf: [32]u8 = undefined;
            const pid_text = std.fmt.bufPrint(&buf, "pid {}", .{running.pid}) catch unreachable;
            p.text(pid_text, g.pidRect(tile), layout.color.muted, .left);
        }
        const button = game.button().style();
        const button_rect = g.buttonRect(tile);
        const button_hot = button.enabled and hovered_tile == index and (if (global.mouse) |m| button_rect.contains(m) else false);
        p.fill(button_rect, if (button_hot) button.fill_hover else button.fill);
        p.text(button.label, button_rect, button.ink, .center);
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
