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

    fn launch(game: *const Game) ?*Launch {
        for (global.launches.items) |*l| {
            if (std.ascii.eqlIgnoreCase(l.name(), game.name)) return l;
        }
        return null;
    }

    fn button(game: *const Game) layout.Button {
        if (game.launch()) |l| return switch (l.state) {
            .launching => .launching,
            .failed => .launch_failed,
        };
        const r = game.running() orelse return .launch;
        return r.button();
    }
};

const IconEntry = struct {
    name_buf: [layout.max_game_name]u8,
    name_len: usize,
    size: u32,
    icon: ?platform.Icon,

    fn name(e: *const IconEntry) []const u8 {
        return e.name_buf[0..e.name_len];
    }
};

fn gameIcon(game_name: []const u8, r: layout.Rect) ?*platform.Icon {
    const size: u32 = @intCast(@max(0, r.right - r.left));
    if (size == 0) return null;
    const entry: *IconEntry = blk: {
        for (global.icons.items) |*e| {
            if (!std.ascii.eqlIgnoreCase(e.name(), game_name)) continue;
            if (e.size == size) return if (e.icon) |*icon| icon else null;
            if (e.icon) |*icon| icon.deinit();
            break :blk e;
        }
        const new = global.icons.addOne(running_allocator) catch |e| {
            std.log.err("out of memory caching the icon for '{s}': {t}", .{ game_name, e });
            return null;
        };
        new.name_len = game_name.len;
        @memcpy(new.name_buf[0..game_name.len], game_name);
        break :blk new;
    };
    entry.size = size;
    entry.icon = null;
    var exe_buf: [max_exepath]u8 = undefined;
    const exe = readExePath(game_name, &exe_buf) catch return null;
    entry.icon = platform.Icon.load(exe, size);
    return if (entry.icon) |*icon| icon else null;
}

const Launch = struct {
    id: u32,
    name_buf: [layout.max_game_name]u8,
    name_len: usize,
    state: enum { launching, failed },

    fn name(l: *const Launch) []const u8 {
        return l.name_buf[0..l.name_len];
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
    var launches: std.ArrayListUnmanaged(Launch) = .empty;
    var icons: std.ArrayListUnmanaged(IconEntry) = .empty;
    var next_launch_id: u32 = 1;
    var picked_pid: ?u32 = null;
    var dropdown_open = false;
    var mouse: ?layout.XY = null;
    var scroll: i32 = 0;
    var drag: ?struct { start_y: i32, start_scroll: i32 } = null;
    var client: layout.XY = .{ .x = 0, .y = 0 };
    var scale: f32 = 1;
    var details: ?Details = null;
};

const running_allocator = std.heap.smp_allocator;

const Details = struct {
    name_buf: [layout.max_game_name]u8,
    name_len: usize,
    exe_buf: [max_exepath]u8,
    exe_len: usize,
    exe_err: ?anyerror,
    mods: ?usize,

    fn name(d: *const Details) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    fn exe(d: *const Details) []const u8 {
        return d.exe_buf[0..d.exe_len];
    }

    fn game(d: *const Details) ?*Game {
        for (global.games.slice()) |*g| if (std.mem.eql(u8, g.name, d.name())) return g;
        return null;
    }
};

const max_exepath = platform.max_exepath;

fn openDetails(game_name: []const u8) void {
    var d: Details = .{
        .name_buf = undefined,
        .name_len = game_name.len,
        .exe_buf = undefined,
        .exe_len = 0,
        .exe_err = null,
        .mods = null,
    };
    @memcpy(d.name_buf[0..game_name.len], game_name);

    if (readExePath(game_name, &d.exe_buf)) |exe| {
        d.exe_len = exe.len;
    } else |err| {
        d.exe_err = err;
    }

    var path_buf: [layout.max_game_name + 1 + "exepath".len]u8 = undefined;
    const mods_rel = std.fmt.bufPrint(&path_buf, "{s}{c}mods", .{ game_name, std.fs.path.sep }) catch unreachable;
    if (global.apps_dir.openDir(mods_rel, .{ .iterate = true })) |mods_dir| {
        var mods = mods_dir;
        defer mods.close();
        var count: usize = 0;
        var it = mods.iterate();
        while (it.next() catch |err| blk: {
            std.log.err("list '{s}' failed: {t}", .{ mods_rel, err });
            break :blk null;
        }) |entry| {
            if (entry.kind == .file) count += 1;
        }
        d.mods = count;
    } else |err| switch (err) {
        error.FileNotFound => d.mods = 0,
        else => std.log.err("open '{s}' failed: {t}", .{ mods_rel, err }),
    }

    global.details = d;
    platform.invalidate();
}

fn readExePath(game_name: []const u8, buf: *[max_exepath]u8) ![]const u8 {
    var path_buf: [layout.max_game_name + 1 + "exepath".len]u8 = undefined;
    const exepath = std.fmt.bufPrint(&path_buf, "{s}{c}exepath", .{ game_name, std.fs.path.sep }) catch unreachable;
    return global.apps_dir.readFile(exepath, buf) catch |err| {
        std.log.err("read '{s}' failed: {t}", .{ exepath, err });
        return err;
    };
}

fn closeDetails() void {
    global.details = null;
    platform.invalidate();
}

fn appPath(buf: []u8, game_name: []const u8, sub: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{c}{s}{s}{s}", .{
        platform.appsDirPath(),
        std.fs.path.sep,
        game_name,
        if (sub.len == 0) "" else std.fs.path.sep_str,
        sub,
    }) catch buf;
}

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
    if (global.details != null) return;
    scrollBy(-layout.scale(grid().rowPitch(), notches));
}

pub fn onKey(key: layout.Key) void {
    if (global.details != null) {
        if (key == .escape) closeDetails();
        return;
    }
    const g = grid();
    switch (key) {
        .escape => {},
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
            if (global.details != null) return;
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
            if (global.details) |*d| {
                const dl: layout.Details = .init(global.client, global.scale);
                if (dl.back.contains(position)) return closeDetails();
                const game = d.game() orelse return closeDetails();
                if (dl.action.contains(position)) return clickButton(game);
                var path_buf: [max_exepath]u8 = undefined;
                if (dl.open_directory.contains(position)) return platform.openDirectory(appPath(&path_buf, game.name, ""));
                if (dl.open_log.contains(position)) return platform.openTextFile(appPath(&path_buf, game.name, "log"));
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
                    openDetails(game.name);
                }
            }
        },
    }
}

fn clickButton(game: *Game) void {
    switch (game.button()) {
        .launch, .launch_failed => clickLaunch(game),
        .launching => {},
        else => clickAttach(game.running().?),
    }
}

fn clickLaunch(game: *Game) void {
    var exe_buf: [max_exepath]u8 = undefined;
    const exe = readExePath(game.name, &exe_buf) catch return;
    const l: *Launch = game.launch() orelse blk: {
        const new = global.launches.addOne(running_allocator) catch |e| {
            std.log.err("out of memory launching '{s}': {t}", .{ game.name, e });
            return;
        };
        new.name_len = game.name.len;
        @memcpy(new.name_buf[0..game.name.len], game.name);
        break :blk new;
    };
    l.id = global.next_launch_id;
    global.next_launch_id += 1;
    l.state = .launching;
    std.log.info("launch '{s}': {s}", .{ game.name, exe });
    platform.launch(l.id, exe);
    platform.invalidate();
}

pub fn onLaunchDone(id: u32, success: bool) void {
    for (global.launches.items, 0..) |*l, index| {
        if (l.id != id) continue;
        if (success) {
            for (global.running.items) |*r| {
                if (std.ascii.eqlIgnoreCase(r.name, l.name())) r.status = .attached;
            }
            _ = global.launches.swapRemove(index);
        } else {
            l.state = .failed;
        }
        break;
    }
    platform.invalidate();
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
    p.clear(layout.color.window, layout.window_alpha);
    if (global.details) |*d| {
        if (d.game()) |game| return paintDetails(p, client, scale, d, game);
        global.details = null;
    }
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
            paintIcon(p, game.name, g.iconRect(tile));
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

fn paintIcon(p: *const platform.Painter, game_name: []const u8, r: layout.Rect) void {
    if (gameIcon(game_name, r)) |icon| {
        p.drawIcon(icon, r);
    } else {
        p.fill(r, layout.color.icon);
    }
}

fn paintDetails(p: *const platform.Painter, client: layout.XY, scale: f32, d: *const Details, game: *Game) void {
    const dl: layout.Details = .init(client, scale);
    const hot = struct {
        fn over(r: layout.Rect) bool {
            return if (global.mouse) |m| r.contains(m) else false;
        }
    };

    p.text(layout.details_text.back, dl.back, if (hot.over(dl.back)) layout.color.text else layout.color.muted, .left);
    paintIcon(p, game.name, dl.icon);
    p.text(game.name, dl.title, layout.color.name, .left);

    var dir_buf: [max_exepath]u8 = undefined;
    var log_buf: [max_exepath]u8 = undefined;
    var mods_buf: [32]u8 = undefined;
    var pid_buf: [32]u8 = undefined;
    const values = [layout.details_text.labels.len][]const u8{
        if (d.exe_err) |err| @errorName(err) else d.exe(),
        if (game.running()) |r| std.fmt.bufPrint(&pid_buf, "pid {}", .{r.pid}) catch unreachable else "not running",
        appPath(&dir_buf, game.name, ""),
        if (d.mods) |count| std.fmt.bufPrint(&mods_buf, "{}", .{count}) catch unreachable else "?",
        appPath(&log_buf, game.name, "log"),
    };
    for (layout.details_text.labels, values, 0..) |label, value, row| {
        p.text(label, dl.labelRect(row), layout.color.muted, .left);
        p.text(value, dl.valueRect(row, client), layout.color.text, .left);
    }

    const style = game.button().style();
    p.fill(dl.action, if (style.enabled and hot.over(dl.action)) style.fill_hover else style.fill);
    p.text(style.label, dl.action, style.ink, .center);
    p.fill(dl.open_directory, if (hot.over(dl.open_directory)) layout.color.button_hover else layout.color.button);
    p.text(layout.details_text.open_directory, dl.open_directory, layout.color.text, .center);
    p.fill(dl.open_log, if (hot.over(dl.open_log)) layout.color.button_hover else layout.color.button);
    p.text(layout.details_text.open_log, dl.open_log, layout.color.text, .center);
}

const std = @import("std");

const layout = @import("layout");
const platform = @import("root");
