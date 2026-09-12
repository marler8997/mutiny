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
};

pub const empty_title = "No games yet.";
pub const empty_body = "Attach to a running Unity game and it will be listed here from then on.";

pub fn scale(value: i32, s: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * s));
}

pub const Grid = struct {
    origin: XY,
    tile: XY,
    gap: XY,
    pad: XY,
    icon: XY,
    icon_text_gap: i32,
    line_height: i32,
    columns: usize,
    rows: usize,

    pub fn init(client: XY, s: f32) Grid {
        const margin = scale(points.margin, s);
        const tile: XY = .{ .x = scale(points.tile_width, s), .y = scale(points.tile_height, s) };
        const gap: XY = .{ .x = scale(points.gap, s), .y = scale(points.gap, s) };
        const usable_x = @max(0, client.x - margin * 2);
        const usable_y = @max(0, client.y - margin * 2);
        return .{
            .origin = .{ .x = margin, .y = margin },
            .tile = tile,
            .gap = gap,
            .pad = .{ .x = scale(points.tile_pad, s), .y = scale(points.tile_pad, s) },
            .icon = .{ .x = scale(points.icon_size, s), .y = scale(points.icon_size, s) },
            .icon_text_gap = scale(points.icon_text_gap, s),
            .line_height = scale(points.line_height, s),
            .columns = @max(1, @as(usize, @intCast(@divTrunc(usable_x + gap.x, tile.x + gap.x)))),
            .rows = @intCast(@divTrunc(usable_y + gap.y, tile.y + gap.y)),
        };
    }

    pub fn visible(grid: Grid) usize {
        return grid.columns * grid.rows;
    }

    pub fn tileRect(grid: Grid, index: usize) Rect {
        const column: i32 = @intCast(index % grid.columns);
        const row: i32 = @intCast(index / grid.columns);
        return Rect.ltwh(
            grid.origin.x + column * (grid.tile.x + grid.gap.x),
            grid.origin.y + row * (grid.tile.y + grid.gap.y),
            grid.tile.x,
            grid.tile.y,
        );
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

    pub fn textLine(grid: Grid, origin: XY, line: i32) Rect {
        return Rect.ltwh(origin.x, origin.y + line * grid.line_height, 4096, grid.line_height);
    }

    pub fn hitTile(grid: Grid, count: usize, p: XY) ?usize {
        for (0..@min(count, grid.visible())) |index| {
            if (grid.tileRect(index).contains(p)) return index;
        }
        return null;
    }
};
