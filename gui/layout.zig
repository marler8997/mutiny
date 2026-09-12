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
};

pub const font_points = 10;
pub const max_game_name = 255;
pub const max_text_len = 512;

const points = struct {
    const margin = 12;
    const tile_width = 170;
    const tile_height = 100;
    const gap = 10;
    const tile_pad = 10;
    const icon_size = 32;
    const icon_text_gap = 8;
    const line_height = 18;
    const scrollbar_width = 8;
    const scrollbar_gap = 6;
    const thumb_min_height = 24;
};

pub const Key = enum { up, down, page_up, page_down, home, end };

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
        const usable_y = @max(0, client.y - margin * 2);

        var usable_x = @max(0, client.x - margin * 2);
        var columns: usize = @max(1, @as(usize, @intCast(@divTrunc(usable_x + gap.x, tile.x + gap.x))));
        var content_height = contentHeight(count, columns, tile.y, gap.y);
        var scrollbar: ?Rect = null;
        if (content_height > usable_y) {
            const bar_width = scale(points.scrollbar_width, s);
            usable_x = @max(0, usable_x - bar_width - scale(points.scrollbar_gap, s));
            columns = @max(1, @as(usize, @intCast(@divTrunc(usable_x + gap.x, tile.x + gap.x))));
            content_height = contentHeight(count, columns, tile.y, gap.y);
            scrollbar = Rect.ltwh(client.x - margin - bar_width, margin, bar_width, usable_y);
        }
        var grid: Grid = .{
            .viewport = Rect.ltwh(margin, margin, usable_x, usable_y),
            .tile = tile,
            .gap = gap,
            .pad = .{ .x = scale(points.tile_pad, s), .y = scale(points.tile_pad, s) },
            .icon = .{ .x = scale(points.icon_size, s), .y = scale(points.icon_size, s) },
            .icon_text_gap = scale(points.icon_text_gap, s),
            .line_height = scale(points.line_height, s),
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
