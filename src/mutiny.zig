const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin");
const win32 = zin.platform.win32;
const appdata = @import("appdata.zig");

pub const zin_config: zin.Config = .{
    .StaticWindowId = StaticWindowId,
};
const StaticWindowId = enum {
    main,
    pub fn getConfig(self: StaticWindowId) zin.WindowConfigData {
        return switch (self) {
            .main => .{
                .window_size_events = true,
                .key_events = true,
                .mouse_events = true,
                .timers = .none,
                .background = .{ .r = 49, .g = 49, .b = 49 },
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
                .x11 = .{ .render_kind = .double_buffered },
            },
        };
    }
};

pub const panic = zin.panic(.{ .title = "Mutiny Panic!" });

const global = struct {
    var class_extra: ?zin.WindowClass = null;
    var mouse_position: ?zin.XY = null;
    var mutiny_dir_exists: ?bool = null;
};

pub fn main() !void {
    // one-time process initialization
    try zin.processInit(.{});

    {
        var err: zin.X11ConnectError = undefined;
        zin.x11Connect(&err) catch std.debug.panic("X11 connect failed: {f}", .{err});
    }
    defer zin.x11Disconnect();

    const icons = getIcons(96, 96);

    zin.staticWindow(.main).registerClass(.{
        .callback = callback,
        .win32_name = zin.L("MutinyMainWindow"),
        .macos_view = "MutinyView",
    }, .{
        .win32_icon_large = icons.large,
        .win32_icon_small = icons.small,
    });
    defer zin.staticWindow(.main).unregisterClass();

    try zin.staticWindow(.main).create(.{
        .title = "Mutiny Game Mods",
        .size = .{ .client_points = .{ .x = 500, .y = 300 } },
        .pos = null,
    });
    defer zin.staticWindow(.main).destroy();
    zin.staticWindow(.main).show();
    // zin.staticWindow(.main).startTimer({}, 14);

    try zin.mainLoop();
}

fn callback(cb: zin.Callback(.{ .static = .main })) void {
    switch (cb) {
        .close => zin.quitMainLoop(),
        .window_size => {},
        .draw => |d| {
            d.clear();

            const localappdata = appdata.get() orelse {
                lineOut(&d, 0, "no LOCALAPPDATA environment variable");
                return;
            };
            var path_buf: [appdata.max_path]u16 = undefined;
            // one subdirectory per game, each holding that game's log and mods
            const games_path = switch (appdata.format(
                &path_buf,
                localappdata,
                &.{win32.L("mutiny")},
            )) {
                .ok => |p| p,
                .too_long => {
                    lineOutFmt(&d, 0, "LOCALAPPDATA ({} chars) is too long", .{localappdata.len});
                    return;
                },
            };
            lineOutFmt(&d, 0, "Games Folder: {f}", .{std.unicode.fmtUtf16Le(games_path)});

            var dir = blk: {
                const prefixed = std.os.windows.wToPrefixedFileW(null, games_path) catch |e| {
                    lineOutFmt(&d, 1, "bad path, {s}", .{@errorName(e)});
                    return;
                };
                break :blk std.fs.cwd().openDirW(prefixed.span(), .{ .iterate = true }) catch |e| {
                    lineOutFmt(&d, 1, "open '{f}' failed with {s}", .{
                        std.unicode.fmtUtf16Le(games_path),
                        @errorName(e),
                    });
                    return;
                };
            };
            defer dir.close();

            var it = dir.iterate();
            var row: i32 = 1;
            while (it.next() catch |err| {
                lineOutFmt(&d, row, "dir next failed with {s}", .{@errorName(err)});
                return;
            }) |entry| {
                lineOut(&d, row, entry.name);
                row += 1;
            }

            // {
            //     const now = std.time.Instant.now() catch @panic("?");
            //     const elapsed_ns = if (global.last_animation) |l| now.since(l) else 0;
            //     global.last_animation = now;

            //     const speed: f32 = 0.0000000001;
            //     global.text_position = @mod(global.text_position + speed * @as(f32, @floatFromInt(elapsed_ns)), 1.0);
            // }

            // const size = zin.staticWindow(.main).getClientSize();
            // d.clear();
            // const animate: zin.XY = .{
            //     .x = @intFromFloat(@round(@as(f32, @floatFromInt(size.x)) * global.text_position)),
            //     .y = @intFromFloat(@round(@as(f32, @floatFromInt(size.y)) * global.text_position)),
            // };
            // const dpi_scale = d.getDpiScale();

            // // currenly only supported on windows
            // if (zin.platform_kind == .win32) {
            //     var pentagon = [5]zin.PolygonPoint{
            //         .xy(zin.scale(i32, 200, dpi_scale.x), zin.scale(i32, 127, dpi_scale.y)), // top
            //         .xy(zin.scale(i32, 232, dpi_scale.x), zin.scale(i32, 150, dpi_scale.y)), // top right
            //         .xy(zin.scale(i32, 220, dpi_scale.x), zin.scale(i32, 187, dpi_scale.y)), // bottom right
            //         .xy(zin.scale(i32, 180, dpi_scale.x), zin.scale(i32, 187, dpi_scale.y)), // bottom left
            //         .xy(zin.scale(i32, 168, dpi_scale.x), zin.scale(i32, 150, dpi_scale.y)), // top left
            //     };
            //     d.polygon(&pentagon, .blue);
            // }

            // const rect_size = zin.scale(i32, 10, dpi_scale.x);
            // d.rect(.ltwh(animate.x, size.y - animate.y, rect_size, rect_size), .red);
            // const margin_left = zin.scale(i32, 10, dpi_scale.x);
            // const top = zin.scale(i32, 50, dpi_scale.y);
            // d.text("Press 'n' to create a new window.", margin_left, top, .white);
            // d.text("Weeee!!!", animate.x, animate.y, .white);
            // if (global.mouse_position) |p| {
            //     d.text("Mouse", p.x, p.y, .white);
            // }
        },
        // .timer => zin.staticWindow(.main).invalidate(),
        .key => |key| {
            _ = key;
            // var keyboard_state: zin.UnicodeKeyboardState = .init();
            // const utf8 = key.utf8(keyboard_state.ref());
        },
        .mouse => |mouse| {
            global.mouse_position = mouse.position;
            zin.staticWindow(.main).invalidate();
        },
    }
}

const margin = 5;
const line_height = 24;

fn lineOut(d: *const zin.Draw(.{ .static = .main }), row: i32, str: []const u8) void {
    d.text(str, margin, margin + row * line_height, .white);
}
fn lineOutFmt(d: *const zin.Draw(.{ .static = .main }), row: i32, comptime fmt: []const u8, args: anytype) void {
    var text_buf: [1000]u8 = undefined;
    lineOut(d, row, std.fmt.bufPrint(&text_buf, fmt, args) catch @panic("string too long"));
}

const Icons = struct {
    small: zin.MaybeWin32Icon,
    large: zin.MaybeWin32Icon,
};
fn getIcons(dpi_x: u32, dpi_y: u32) Icons {
    if (builtin.os.tag == .windows) {
        const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi_x);
        const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi_y);
        const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi_x);
        const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi_y);
        std.log.info("icons small={}x{} large={}x{} at dpi {}x{}", .{
            small_x, small_y,
            large_x, large_y,
            dpi_x,   dpi_y,
        });
        const small = win32.LoadImageW(
            win32.GetModuleHandleW(null),
            @ptrFromInt(1), // resource id
            .ICON,
            small_x,
            small_y,
            win32.LR_SHARED,
        );
        if (small == null)
            std.debug.panic("LoadImage for small icon failed, error={f}", .{win32.GetLastError()});
        const large = win32.LoadImageW(
            win32.GetModuleHandleW(null),
            @ptrFromInt(1), // resource id
            .ICON,
            large_x,
            large_y,
            win32.LR_SHARED,
        );
        if (large == null)
            std.debug.panic("LoadImage for large icon failed, error={f}", .{win32.GetLastError()});
        return .{
            .small = .init(@ptrCast(small)),
            .large = .init(@ptrCast(large)),
        };
    }
    return .{ .small = .none, .large = .none };
}
