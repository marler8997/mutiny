pub const XY = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn ltwh(left: i32, top: i32, width: i32, height: i32) Rect {
        return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
    }
    pub fn inset(r: Rect, by: i32) Rect {
        return .{ .left = r.left + by, .top = r.top + by, .right = r.right - by, .bottom = r.bottom - by };
    }
    pub fn contains(r: Rect, p: XY) bool {
        return p.x >= r.left and p.x < r.right and p.y >= r.top and p.y < r.bottom;
    }
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const color = struct {
    pub const window: Rgb = .{ .r = 49, .g = 49, .b = 49 };
    pub const bar: Rgb = .{ .r = 43, .g = 43, .b = 43 };
    pub const dropdown: Rgb = .{ .r = 36, .g = 36, .b = 36 };
    pub const track: Rgb = .{ .r = 42, .g = 42, .b = 42 };
    pub const thumb: Rgb = .{ .r = 90, .g = 90, .b = 90 };
    pub const thumb_hover: Rgb = .{ .r = 106, .g = 106, .b = 106 };
    pub const tile: Rgb = .{ .r = 58, .g = 58, .b = 58 };
    pub const tile_hover: Rgb = .{ .r = 68, .g = 68, .b = 68 };
    pub const tile_edge: Rgb = .{ .r = 71, .g = 71, .b = 71 };
    pub const icon: Rgb = .{ .r = 47, .g = 47, .b = 47 };
    pub const text: Rgb = .{ .r = 232, .g = 230, .b = 225 };
    pub const muted: Rgb = .{ .r = 154, .g = 152, .b = 147 };
    pub const name: Rgb = .{ .r = 140, .g = 204, .b = 255 };
    pub const name_hover: Rgb = .{ .r = 184, .g = 223, .b = 255 };
    pub const button: Rgb = .{ .r = 76, .g = 76, .b = 76 };
    pub const button_hover: Rgb = .{ .r = 88, .g = 88, .b = 88 };
    pub const button_disabled: Rgb = .{ .r = 63, .g = 63, .b = 63 };
    pub const accent: Rgb = .{ .r = 140, .g = 204, .b = 255 };
    pub const accent_hover: Rgb = .{ .r = 166, .g = 216, .b = 255 };
    pub const accent_ink: Rgb = .{ .r = 18, .g = 40, .b = 58 };
    pub const launch: Rgb = .{ .r = 232, .g = 230, .b = 225 };
    pub const launch_hover: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    pub const launch_ink: Rgb = .{ .r = 31, .g = 31, .b = 31 };
    pub const failed: Rgb = .{ .r = 74, .g = 53, .b = 53 };
    pub const failed_hover: Rgb = .{ .r = 90, .g = 64, .b = 64 };
    pub const ok: Rgb = .{ .r = 127, .g = 212, .b = 138 };
    pub const bad: Rgb = .{ .r = 255, .g = 102, .b = 102 };
};

pub const TextAlign = enum { left, center };

pub const Button = enum {
    launch,
    attach,
    attached,
    attaching,
    not_responding,
    attach_failed,

    pub const Style = struct {
        label: []const u8,
        fill: Rgb,
        fill_hover: Rgb,
        ink: Rgb,
        enabled: bool,
    };

    pub fn style(button: Button) Style {
        return switch (button) {
            .launch => .{ .label = "Launch", .fill = color.launch, .fill_hover = color.launch_hover, .ink = color.launch_ink, .enabled = true },
            .attach => .{ .label = "Attach", .fill = color.accent, .fill_hover = color.accent_hover, .ink = color.accent_ink, .enabled = true },
            .attached => .{ .label = "Attached", .fill = color.button_disabled, .fill_hover = color.button_disabled, .ink = color.ok, .enabled = false },
            .attaching => .{ .label = "Attaching…", .fill = color.button_disabled, .fill_hover = color.button_disabled, .ink = color.muted, .enabled = false },
            .not_responding => .{ .label = "Not responding", .fill = color.button_disabled, .fill_hover = color.button_disabled, .ink = color.bad, .enabled = false },
            .attach_failed => .{ .label = "Attach failed · retry", .fill = color.failed, .fill_hover = color.failed_hover, .ink = color.bad, .enabled = true },
        };
    }
};

pub const font_points = 10;
pub const max_game_name = 255;
pub const max_text_len = 512;

const points = struct {
    const margin = 12;
    const tile_width = 170;
    const tile_height = 110;
    const gap = 10;
    const tile_pad = 10;
    const icon_size = 32;
    const icon_text_gap = 8;
    const line_height = 18;
    const button_height = 24;
    const scrollbar_width = 8;
    const scrollbar_gap = 6;
    const thumb_min_height = 24;
    const bar_height = 36;
    const bar_pad = 10;
    const bar_gap = 10;
    const bar_label_width = 150;
    const bar_attach_width = 90;
    const dropdown_item_height = 26;
    const details_back_width = 70;
    const details_label_width = 90;
    const details_button_width = 120;
};

pub const bar_text = struct {
    pub const none_running = "No Unity games are running. Launch one; it appears here when its window opens.";
    pub const all_known = "Every running Unity game is set up. New ones appear here when their window opens.";
    pub const one_new = "New game running:";
    pub const many_new = "new games running:";
};

pub const Bar = struct {
    rect: Rect,
    label: Rect,
    name: Rect,
    attach: Rect,
    item_height: i32,

    pub fn init(client: XY, s: f32) Bar {
        const margin = scale(points.margin, s);
        const pad = scale(points.bar_pad, s);
        const gap = scale(points.bar_gap, s);
        const height = scale(points.bar_height, s);
        const rect = Rect.ltwh(margin, margin, @max(0, client.x - margin * 2), height);
        const inner_top = rect.top + pad;
        const inner_bottom = rect.bottom - pad;
        const label_width = scale(points.bar_label_width, s);
        const attach_width = scale(points.bar_attach_width, s);
        const label: Rect = .{ .left = rect.left + pad, .top = inner_top, .right = rect.left + pad + label_width, .bottom = inner_bottom };
        const attach: Rect = .{ .left = rect.right - pad - attach_width, .top = inner_top, .right = rect.right - pad, .bottom = inner_bottom };
        return .{
            .rect = rect,
            .label = label,
            .name = .{ .left = label.right + gap, .top = inner_top, .right = @max(label.right + gap, attach.left - gap), .bottom = inner_bottom },
            .attach = attach,
            .item_height = scale(points.dropdown_item_height, s),
        };
    }

    pub fn message(bar: Bar) Rect {
        return .{ .left = bar.label.left, .top = bar.label.top, .right = bar.rect.right - (bar.label.left - bar.rect.left), .bottom = bar.label.bottom };
    }

    pub fn dropdownRect(bar: Bar, count: usize) Rect {
        return Rect.ltwh(bar.name.left, bar.name.bottom + 2, bar.name.right - bar.name.left, bar.item_height * @as(i32, @intCast(count)));
    }

    pub fn dropdownItem(bar: Bar, index: usize) Rect {
        const list = bar.dropdownRect(index + 1);
        return .{ .left = list.left, .top = list.bottom - bar.item_height, .right = list.right, .bottom = list.bottom };
    }

    pub fn hitDropdown(bar: Bar, count: usize, p: XY) ?usize {
        for (0..count) |index| if (bar.dropdownItem(index).contains(p)) return index;
        return null;
    }
};

pub const Key = enum { up, down, page_up, page_down, home, end, escape };

pub const details_text = struct {
    pub const back = "← Games";
    pub const labels = [_][]const u8{ "Executable", "Process", "Directory", "Mods", "Log" };
    pub const open_directory = "Open directory";
    pub const open_log = "Open log";
};

pub const Details = struct {
    back: Rect,
    icon: Rect,
    title: Rect,
    label_column: i32,
    value_left: i32,
    rows_top: i32,
    line_height: i32,
    action: Rect,
    open_directory: Rect,
    open_log: Rect,

    pub fn init(client: XY, s: f32) Details {
        const margin = scale(points.margin, s);
        const line_height = scale(points.line_height, s);
        const bar_height = scale(points.bar_height, s);
        const pad = scale(points.bar_pad, s);
        const gap = scale(points.bar_gap, s);
        const width = @max(0, client.x - margin * 2);
        const head_top = margin;
        const head_bottom = margin + bar_height;
        const back_width = scale(points.details_back_width, s);
        const label_width = scale(points.details_label_width, s);
        const button_height = scale(points.button_height, s);
        const button_width = scale(points.details_button_width, s);
        const icon = scale(points.icon_size, s);
        const icon_left = margin + back_width + gap;
        const rows_top = head_bottom + gap;
        const actions_top = rows_top + line_height * @as(i32, @intCast(details_text.labels.len)) + gap * 2;
        return .{
            .back = .{ .left = margin, .top = head_top, .right = margin + back_width, .bottom = head_bottom },
            .icon = Rect.ltwh(icon_left, head_top + @divTrunc(bar_height - icon, 2), icon, icon),
            .title = .{ .left = icon_left + icon + gap, .top = head_top, .right = margin + width, .bottom = head_bottom },
            .label_column = margin + pad,
            .value_left = margin + pad + label_width,
            .rows_top = rows_top,
            .line_height = line_height,
            .action = Rect.ltwh(margin, actions_top, button_width, button_height),
            .open_directory = Rect.ltwh(margin + button_width + gap, actions_top, button_width, button_height),
            .open_log = Rect.ltwh(margin + (button_width + gap) * 2, actions_top, button_width, button_height),
        };
    }

    pub fn labelRect(d: Details, row: usize) Rect {
        const top = d.rows_top + d.line_height * @as(i32, @intCast(row));
        return .{ .left = d.label_column, .top = top, .right = d.value_left, .bottom = top + d.line_height };
    }

    pub fn valueRect(d: Details, row: usize, client: XY) Rect {
        const top = d.rows_top + d.line_height * @as(i32, @intCast(row));
        return .{ .left = d.value_left, .top = top, .right = client.x - d.label_column, .bottom = top + d.line_height };
    }
};

pub const MouseButton = enum { left };
pub const ButtonState = enum { down, up };

pub const empty_title = "No games yet.";
pub const empty_body = "Attach to a running Unity game and it will be listed here from then on.";

pub fn scale(value: i32, s: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * s));
}

pub const Grid = struct {
    viewport: Rect,
    tile: XY,
    gap: XY,
    pad: XY,
    icon: XY,
    icon_text_gap: i32,
    line_height: i32,
    button_height: i32,
    columns: usize,
    count: usize,
    content_height: i32,
    scroll: i32,
    scrollbar: ?Rect,
    thumb_min_height: i32,

    pub fn init(client: XY, s: f32, count: usize, wanted_scroll: i32) Grid {
        const margin = scale(points.margin, s);
        const tile: XY = .{ .x = scale(points.tile_width, s), .y = scale(points.tile_height, s) };
        const gap: XY = .{ .x = scale(points.gap, s), .y = scale(points.gap, s) };
        const top = margin + scale(points.bar_height, s) + gap.y;
        const usable_y = @max(0, client.y - top - margin);

        var usable_x = @max(0, client.x - margin * 2);
        var columns: usize = @max(1, @as(usize, @intCast(@divTrunc(usable_x + gap.x, tile.x + gap.x))));
        var content_height = contentHeight(count, columns, tile.y, gap.y);
        var scrollbar: ?Rect = null;
        if (content_height > usable_y) {
            const bar_width = scale(points.scrollbar_width, s);
            usable_x = @max(0, usable_x - bar_width - scale(points.scrollbar_gap, s));
            columns = @max(1, @as(usize, @intCast(@divTrunc(usable_x + gap.x, tile.x + gap.x))));
            content_height = contentHeight(count, columns, tile.y, gap.y);
            scrollbar = Rect.ltwh(client.x - margin - bar_width, top, bar_width, usable_y);
        }
        var grid: Grid = .{
            .viewport = Rect.ltwh(margin, top, usable_x, usable_y),
            .tile = tile,
            .gap = gap,
            .pad = .{ .x = scale(points.tile_pad, s), .y = scale(points.tile_pad, s) },
            .icon = .{ .x = scale(points.icon_size, s), .y = scale(points.icon_size, s) },
            .icon_text_gap = scale(points.icon_text_gap, s),
            .line_height = scale(points.line_height, s),
            .button_height = scale(points.button_height, s),
            .columns = columns,
            .count = count,
            .content_height = content_height,
            .scroll = 0,
            .scrollbar = scrollbar,
            .thumb_min_height = scale(points.thumb_min_height, s),
        };
        grid.scroll = grid.clampScroll(wanted_scroll);
        return grid;
    }

    fn contentHeight(count: usize, columns: usize, tile_height: i32, gap: i32) i32 {
        const rows: i32 = @intCast((count + columns - 1) / columns);
        return @max(0, rows * (tile_height + gap) - gap);
    }

    pub fn viewportHeight(grid: Grid) i32 {
        return grid.viewport.bottom - grid.viewport.top;
    }

    pub fn maxScroll(grid: Grid) i32 {
        return @max(0, grid.content_height - grid.viewportHeight());
    }

    pub fn clampScroll(grid: Grid, wanted: i32) i32 {
        return std.math.clamp(wanted, 0, grid.maxScroll());
    }

    pub fn rowPitch(grid: Grid) i32 {
        return grid.tile.y + grid.gap.y;
    }

    pub fn visibleRange(grid: Grid) struct { first: usize, end: usize } {
        const pitch = grid.rowPitch();
        const first_row: usize = @intCast(@divTrunc(grid.scroll, pitch));
        const last_row: usize = @intCast(@divTrunc(grid.scroll + grid.viewportHeight() + pitch - 1, pitch));
        return .{
            .first = @min(grid.count, first_row * grid.columns),
            .end = @min(grid.count, last_row * grid.columns),
        };
    }

    pub fn tileRect(grid: Grid, index: usize) Rect {
        const column: i32 = @intCast(index % grid.columns);
        const row: i32 = @intCast(index / grid.columns);
        return Rect.ltwh(
            grid.viewport.left + column * (grid.tile.x + grid.gap.x),
            grid.viewport.top + row * grid.rowPitch() - grid.scroll,
            grid.tile.x,
            grid.tile.y,
        );
    }

    pub fn thumbRect(grid: Grid) ?Rect {
        const track = grid.scrollbar orelse return null;
        const track_height = track.bottom - track.top;
        const height = @max(
            grid.thumb_min_height,
            @as(i32, @intCast(@divTrunc(@as(i64, track_height) * @as(i64, grid.viewportHeight()), @as(i64, grid.content_height)))),
        );
        const travel = track_height - height;
        const max_scroll = grid.maxScroll();
        const top = if (max_scroll == 0) 0 else @as(i32, @intCast(@divTrunc(@as(i64, travel) * @as(i64, grid.scroll), @as(i64, max_scroll))));
        return Rect.ltwh(track.left, track.top + top, track.right - track.left, height);
    }

    pub fn scrollFromDrag(grid: Grid, start_scroll: i32, dy: i32) i32 {
        const track = grid.scrollbar orelse return start_scroll;
        const thumb = grid.thumbRect() orelse return start_scroll;
        const travel = (track.bottom - track.top) - (thumb.bottom - thumb.top);
        if (travel <= 0) return start_scroll;
        const delta = @divTrunc(@as(i64, dy) * @as(i64, grid.maxScroll()), @as(i64, travel));
        return grid.clampScroll(@intCast(std.math.clamp(@as(i64, start_scroll) + delta, 0, std.math.maxInt(i32))));
    }

    pub fn headerRect(grid: Grid, tile: Rect) Rect {
        return .{
            .left = tile.left + grid.pad.x,
            .top = tile.top + grid.pad.y,
            .right = tile.right - grid.pad.x,
            .bottom = tile.top + grid.pad.y + grid.icon.y,
        };
    }

    pub fn iconRect(grid: Grid, tile: Rect) Rect {
        return Rect.ltwh(tile.left + grid.pad.x, tile.top + grid.pad.y, grid.icon.x, grid.icon.y);
    }

    pub fn nameRect(grid: Grid, tile: Rect) Rect {
        return .{
            .left = tile.left + grid.pad.x + grid.icon.x + grid.icon_text_gap,
            .top = tile.top + grid.pad.y,
            .right = tile.right - grid.pad.x,
            .bottom = tile.top + grid.pad.y + grid.icon.y,
        };
    }

    pub fn pidRect(grid: Grid, tile: Rect) Rect {
        const top = tile.top + grid.pad.y + grid.icon.y + @divTrunc(grid.gap.y, 2);
        return .{
            .left = tile.left + grid.pad.x,
            .top = top,
            .right = tile.right - grid.pad.x,
            .bottom = top + grid.line_height,
        };
    }

    pub fn buttonRect(grid: Grid, tile: Rect) Rect {
        return .{
            .left = tile.left + grid.pad.x,
            .top = tile.bottom - grid.pad.y - grid.button_height,
            .right = tile.right - grid.pad.x,
            .bottom = tile.bottom - grid.pad.y,
        };
    }

    pub fn textLine(grid: Grid, line: i32) Rect {
        return Rect.ltwh(grid.viewport.left, grid.viewport.top + line * grid.line_height, 4096, grid.line_height);
    }

    pub fn hitTile(grid: Grid, p: XY) ?usize {
        if (!grid.viewport.contains(p)) return null;
        const range = grid.visibleRange();
        for (range.first..range.end) |index| {
            if (grid.tileRect(index).contains(p)) return index;
        }
        return null;
    }
};

const std = @import("std");
