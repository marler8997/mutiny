pub const title = "Mutiny";
pub const initial_client_points: layout.XY = .{ .x = 640, .y = 420 };

pub const Status = enum { not_attached, attached, unresponsive };

pub const Running = struct {
    pid: u32,
    name: []const u8,
    status: Status,
    attach: enum { idle, attaching, failed } = .idle,

    fn button(running: *const Running) layout.Button {
        return switch (running.attach) {
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

const Game = struct {
    name: []const u8,

    fn running(game: *const Game) ?*Running {
        for (global.running.items) |*r| {
            if (std.ascii.eqlIgnoreCase(r.name, game.name)) return r;
        }
        return null;
    }

    fn button(game: *const Game) layout.Button {
        const r = game.running() orelse return .launch;
        return r.button();
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
    var running: std.ArrayListUnmanaged(Running) = .empty;
    var picked_pid: ?u32 = null;
    var dropdown_open = false;
    var mouse: ?layout.XY = null;
    var scroll: i32 = 0;
    var drag: ?struct { start_y: i32, start_scroll: i32 } = null;
    var client: layout.XY = .{ .x = 0, .y = 0 };
    var scale: f32 = 1;
};

const running_allocator = std.heap.smp_allocator;

pub fn init(apps_dir: std.fs.Dir) void {
    global.apps_dir = apps_dir;
    loadGames();
}

pub fn onAppsDirChanged() void {
    loadGames();
    platform.invalidate();
}

pub fn onGameWindowCreated(pid: u32, name: []const u8, status: Status) void {
    if (findRunning(pid)) |existing| {
        existing.status = status;
    } else {
        const owned = running_allocator.dupe(u8, name) catch |e| {
            std.log.err("out of memory recording pid {} '{s}': {t}", .{ pid, name, e });
            return;
        };
        global.running.append(running_allocator, .{ .pid = pid, .name = owned, .status = status }) catch |e| {
            running_allocator.free(owned);
            std.log.err("out of memory recording pid {} '{s}': {t}", .{ pid, name, e });
            return;
        };
        std.log.info("game window: pid {} '{s}' ({t})", .{ pid, name, status });
        if (!isKnown(name)) global.picked_pid = pid;
    }
    platform.invalidate();
}

pub fn onGameExited(pid: u32) void {
    for (global.running.items, 0..) |r, index| {
        if (r.pid != pid) continue;
        std.log.info("game exited: pid {} '{s}'", .{ pid, r.name });
        running_allocator.free(r.name);
        _ = global.running.orderedRemove(index);
        break;
    }
    if (global.picked_pid == pid) global.picked_pid = null;
    platform.invalidate();
}

pub fn onGameAttached(pid: u32) void {
    const r = findRunning(pid) orelse return;
    r.status = .attached;
    r.attach = .idle;
    platform.invalidate();
}

pub fn onAttachDone(pid: u32, success: bool) void {
    const r = findRunning(pid) orelse return;
    r.attach = if (success) .idle else .failed;
    if (success) r.status = .attached;
    platform.invalidate();
}

fn findRunning(pid: u32) ?*Running {
    for (global.running.items) |*r| if (r.pid == pid) return r;
    return null;
}

fn isKnown(name: []const u8) bool {
    for (global.games.slice()) |game| if (std.ascii.eqlIgnoreCase(game.name, name)) return true;
    return false;
}

const max_unknown = 32;

fn unknownRunning(buf: *[max_unknown]*Running) []*Running {
    var count: usize = 0;
    for (global.running.items) |*r| {
        if (isKnown(r.name)) continue;
        if (count == buf.len) {
            std.log.warn("more than {} unknown running games, ignoring the rest", .{max_unknown});
            break;
        }
        buf[count] = r;
        count += 1;
    }
    return buf[0..count];
}

fn pickedRunning(unknown: []*Running) ?*Running {
    if (unknown.len == 0) return null;
    if (global.picked_pid) |pid| for (unknown) |r| if (r.pid == pid) return r;
    return unknown[unknown.len - 1];
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

fn bar() layout.Bar {
    return .init(global.client, global.scale);
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
    defer platform.invalidate();
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
                return;
            }
            var unknown_buf: [max_unknown]*Running = undefined;
            const unknown = unknownRunning(&unknown_buf);
            const b = bar();
            if (global.dropdown_open) {
                global.dropdown_open = false;
                if (b.hitDropdown(unknown.len, position)) |index| global.picked_pid = unknown[index].pid;
                return;
            }
            if (pickedRunning(unknown)) |picked| {
                if (unknown.len > 1 and b.name.contains(position)) {
                    global.dropdown_open = true;
                    return;
                }
                if (b.attach.contains(position)) {
                    clickAttach(picked);
                    return;
                }
            }
            if (g.hitTile(position)) |index| {
                const game = &global.games.slice()[index];
                const tile = g.tileRect(index);
                if (g.buttonRect(tile).contains(position)) {
                    clickButton(game);
                } else if (g.headerRect(tile).contains(position)) {
                    std.log.info("details for '{s}': not implemented yet", .{game.name});
                }
            }
        },
    }
}

fn clickButton(game: *Game) void {
    switch (game.button()) {
        .launch => std.log.info("launch '{s}': not implemented yet", .{game.name}),
        else => clickAttach(game.running().?),
    }
}

fn clickAttach(r: *Running) void {
    switch (r.button()) {
        .attach, .attach_failed => {
            r.attach = .attaching;
            platform.attach(r.pid);
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
        games.list.append(allocator, .{ .name = name }) catch |e| {
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
    const hovered_tile = if (global.mouse) |m| g.hitTile(m) else null;

    var unknown_buf: [max_unknown]*Running = undefined;
    const unknown = unknownRunning(&unknown_buf);
    const b = bar();
    const picked = pickedRunning(unknown);
    p.fill(b.rect, layout.color.bar);
    if (picked) |r| {
        var label_buf: [48]u8 = undefined;
        const label = if (unknown.len == 1) layout.bar_text.one_new else std.fmt.bufPrint(&label_buf, "{} {s}", .{ unknown.len, layout.bar_text.many_new }) catch layout.bar_text.many_new;
        p.text(label, b.label, layout.color.muted, .left);
        const name_hot = unknown.len > 1 and (if (global.mouse) |m| b.name.contains(m) else false);
        p.fill(b.name, if (name_hot or global.dropdown_open) layout.color.button_hover else layout.color.button);
        var name_buf: [layout.max_game_name + 32]u8 = undefined;
        const name_text = std.fmt.bufPrint(&name_buf, "{s} · pid {}{s}", .{ r.name, r.pid, if (unknown.len > 1) "  ▾" else "" }) catch r.name;
        p.text(name_text, b.name.inset(0), layout.color.name, .center);
        const style = r.button().style();
        const attach_hot = style.enabled and (if (global.mouse) |m| b.attach.contains(m) else false);
        p.fill(b.attach, if (attach_hot) style.fill_hover else style.fill);
        p.text(style.label, b.attach, style.ink, .center);
    } else {
        p.text(if (global.running.items.len == 0) layout.bar_text.none_running else layout.bar_text.all_known, b.message(), layout.color.muted, .left);
    }

    if (games.err) |err| {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ err.what, err.name }) catch err.what;
        p.text(text, g.textLine(0), layout.color.text, .left);
    } else if (games.slice().len == 0) {
        p.text(layout.empty_title, g.textLine(0), layout.color.text, .left);
        p.text(layout.empty_body, g.textLine(1), layout.color.muted, .left);
    } else {
        const range = g.visibleRange();
        p.pushClip(g.viewport);
        for (games.slice()[range.first..range.end], range.first..) |*game, index| {
            const tile = g.tileRect(index);
            p.fill(tile, layout.color.tile_edge);
            p.fill(tile.inset(1), layout.color.tile);
            const header = g.headerRect(tile);
            const header_hot = hovered_tile == index and (if (global.mouse) |m| header.contains(m) else false);
            if (header_hot) p.fill(header, layout.color.tile_hover);
            p.fill(g.iconRect(tile), layout.color.icon);
            p.text(game.name, g.nameRect(tile), if (header_hot) layout.color.name_hover else layout.color.name, .left);
            if (game.running()) |r| {
                var buf: [32]u8 = undefined;
                const pid_text = std.fmt.bufPrint(&buf, "pid {}", .{r.pid}) catch unreachable;
                p.text(pid_text, g.pidRect(tile), layout.color.muted, .left);
            }
            const style = game.button().style();
            const button_rect = g.buttonRect(tile);
            const button_hot = style.enabled and hovered_tile == index and (if (global.mouse) |m| button_rect.contains(m) else false);
            p.fill(button_rect, if (button_hot) style.fill_hover else style.fill);
            p.text(style.label, button_rect, style.ink, .center);
        }
        p.popClip();

        if (g.scrollbar) |track| {
            p.fill(track, layout.color.track);
            const thumb = g.thumbRect().?;
            const hot = global.drag != null or (if (global.mouse) |m| thumb.contains(m) else false);
            p.fill(thumb, if (hot) layout.color.thumb_hover else layout.color.thumb);
        }
    }

    if (global.dropdown_open and unknown.len > 1) {
        p.fill(b.dropdownRect(unknown.len), layout.color.dropdown);
        for (unknown, 0..) |r, index| {
            const item = b.dropdownItem(index);
            const hot = if (global.mouse) |m| item.contains(m) else false;
            if (hot) p.fill(item, layout.color.button_hover);
            var buf: [layout.max_game_name + 32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} · pid {}", .{ r.name, r.pid }) catch r.name;
            p.text(text, item.inset(4), if (picked != null and picked.?.pid == r.pid) layout.color.name else layout.color.text, .left);
        }
    }
}

const std = @import("std");

const layout = @import("layout.zig");
const platform = @import("root");
