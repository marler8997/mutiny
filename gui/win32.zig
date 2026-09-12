pub const panic = std.debug.FullPanic(panicFn);
fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    var buf: [1024]u8 = undefined;
    const msg_z = std.fmt.bufPrintZ(&buf, "{s}", .{msg}) catch "panic message too long";
    _ = win32.MessageBoxA(null, msg_z, "Mutiny Panic!", .{});
    std.debug.defaultPanic(msg, ret_addr);
}

const global = struct {
    var hwnd: win32.HWND = undefined;
    var tracking_mouse = false;
};

const window_class_name = win32.L("MutinyMainWindow");
const window_title = win32.L(app.title);

pub fn main() void {
    {
        var awareness: win32.PROCESS_DPI_AWARENESS = undefined;
        const hr = win32.GetProcessDpiAwareness(null, &awareness);
        if (hr < 0) std.debug.panic("GetProcessDpiAwareness failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
        switch (awareness) {
            .PER_MONITOR_DPI_AWARE => {},
            else => |a| std.debug.panic("the process is {t}, the manifest should make it PER_MONITOR_DPI_AWARE", .{a}),
        }
    }

    var apps_path_buf: [appdata.max_path]u16 = undefined;
    const apps_path = blk: {
        const localappdata = appdata.get() orelse std.debug.panic("no LOCALAPPDATA environment variable", .{});
        const path = switch (appdata.format(
            &apps_path_buf,
            localappdata,
            &.{ win32.L("mutiny"), win32.L("app") },
        )) {
            .ok => |p| p,
            .too_long => std.debug.panic("LOCALAPPDATA ({} chars) is too long", .{localappdata.len}),
        };
        if (appdata.makeDirs(&apps_path_buf, path.len)) |err| win32.panicWin32("CreateDirectory", err);
        break :blk path;
    };

    const watch: win32.HANDLE = blk: {
        const handle = win32.FindFirstChangeNotificationW(
            apps_path,
            1,
            .{ .FILE_NAME = 1, .DIR_NAME = 1, .LAST_WRITE = 1 },
        );
        if (@as(usize, @bitCast(handle)) == @intFromPtr(win32.INVALID_HANDLE_VALUE)) win32.panicWin32(
            "FindFirstChangeNotification",
            win32.GetLastError(),
        );
        break :blk @ptrFromInt(@as(usize, @bitCast(handle)));
    };

    {
        const prefixed = std.os.windows.wToPrefixedFileW(null, apps_path) catch |e| std.debug.panic(
            "bad app directory path '{f}': {t}",
            .{ std.unicode.fmtUtf16Le(apps_path), e },
        );
        const dir = std.fs.cwd().openDirW(prefixed.span(), .{ .iterate = true }) catch |e| std.debug.panic(
            "open '{f}' failed: {t}",
            .{ std.unicode.fmtUtf16Le(apps_path), e },
        );
        app.init(dir);
    }

    const hinstance = win32.GetModuleHandleW(null);
    {
        const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), 96);
        const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), 96);
        const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), 96);
        const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), 96);
        const small = win32.LoadImageW(hinstance, @ptrFromInt(1), .ICON, small_x, small_y, win32.LR_SHARED) orelse
            std.debug.panic("LoadImage for small icon failed, error={f}", .{win32.GetLastError()});
        const large = win32.LoadImageW(hinstance, @ptrFromInt(1), .ICON, large_x, large_y, win32.LR_SHARED) orelse
            std.debug.panic("LoadImage for large icon failed, error={f}", .{win32.GetLastError()});
        const wc: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = @ptrCast(large),
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = window_class_name,
            .hIconSm = @ptrCast(small),
        };
        if (0 == win32.RegisterClassExW(&wc)) win32.panicWin32("RegisterClassEx", win32.GetLastError());
    }

    const style: win32.WINDOW_STYLE = win32.WS_OVERLAPPEDWINDOW;
    const style_ex: win32.WINDOW_EX_STYLE = .{};
    const hwnd = win32.CreateWindowExW(
        style_ex,
        window_class_name,
        window_title,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        null,
        hinstance,
        null,
    ) orelse win32.panicWin32("CreateWindowEx", win32.GetLastError());
    global.hwnd = hwnd;

    {
        const dpi = win32.dpiFromHwnd(hwnd);
        const s = dpiScale(dpi);
        var rect: win32.RECT = .{
            .left = 0,
            .top = 0,
            .right = layout.scale(app.initial_client_points.x, s),
            .bottom = layout.scale(app.initial_client_points.y, s),
        };
        if (0 == win32.AdjustWindowRectExForDpi(&rect, style, 0, style_ex, dpi)) win32.panicWin32(
            "AdjustWindowRectExForDpi",
            win32.GetLastError(),
        );
        if (0 == win32.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
            .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
        )) win32.panicWin32("SetWindowPos", win32.GetLastError());
    }

    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var handles = [_]?win32.HANDLE{watch};
    while (true) {
        switch (win32.MsgWaitForMultipleObjects(handles.len, &handles, 0, win32.INFINITE, win32.QS_ALLINPUT)) {
            @intFromEnum(win32.WAIT_OBJECT_0) => {
                if (0 == win32.FindNextChangeNotification(@bitCast(@intFromPtr(watch)))) win32.panicWin32(
                    "FindNextChangeNotification",
                    win32.GetLastError(),
                );
                app.onAppsDirChanged();
            },
            @intFromEnum(win32.WAIT_OBJECT_0) + handles.len => {
                var msg: win32.MSG = undefined;
                while (0 != win32.PeekMessageW(&msg, null, 0, 0, .{ .REMOVE = 1 })) {
                    if (msg.message == win32.WM_QUIT) return;
                    _ = win32.TranslateMessage(&msg);
                    _ = win32.DispatchMessageW(&msg);
                }
            },
            else => |result| std.debug.panic(
                "MsgWaitForMultipleObjects returned {} (error={f})",
                .{ result, win32.GetLastError() },
            ),
        }
    }
}

pub fn invalidate() void {
    win32.invalidateHwnd(global.hwnd);
}

fn dpiScale(dpi: u32) f32 {
    return @as(f32, @floatFromInt(dpi)) / 96.0;
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_PAINT => {
            const paintdc, const ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const size = win32.getClientSize(hwnd);
            const memdc = win32.CreateCompatibleDC(paintdc);
            defer win32.deleteDc(memdc);
            const bmp = win32.CreateCompatibleBitmap(paintdc, size.cx, size.cy) orelse win32.panicWin32("CreateCompatibleBitmap", win32.GetLastError());
            defer win32.deleteObject(bmp);
            const old_bmp = win32.SelectObject(memdc, bmp);
            defer _ = win32.SelectObject(memdc, old_bmp);

            const dpi = win32.dpiFromHwnd(hwnd);
            const font = win32.CreateFontW(
                -@as(i32, @intCast(win32.MulDiv(layout.font_points, @intCast(dpi), 72))),
                0,
                0,
                0,
                @intCast(win32.FW_NORMAL),
                0,
                0,
                0,
                win32.DEFAULT_CHARSET,
                .DEFAULT_PRECIS,
                win32.CLIP_DEFAULT_PRECIS,
                .CLEARTYPE_QUALITY,
                .DONTCARE,
                win32.L("Segoe UI"),
            ) orelse win32.panicWin32("CreateFont", win32.GetLastError());
            defer win32.deleteObject(font);
            const old_font = win32.SelectObject(memdc, font);
            defer _ = win32.SelectObject(memdc, old_font);
            if (0 == win32.SetBkMode(memdc, .TRANSPARENT)) win32.panicWin32("SetBkMode", win32.GetLastError());

            const painter: Painter = .{ .hdc = memdc };
            app.onPaint(&painter, .{ .x = size.cx, .y = size.cy }, dpiScale(dpi));

            if (0 == win32.BitBlt(paintdc, 0, 0, size.cx, size.cy, memdc, 0, 0, win32.SRCCOPY)) win32.panicWin32("BitBlt", win32.GetLastError());
            return 0;
        },
        win32.WM_SIZE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_DPICHANGED => {
            const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (0 == win32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                .{ .NOZORDER = 1, .NOACTIVATE = 1 },
            )) win32.panicWin32("SetWindowPos", win32.GetLastError());
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const p = win32.pointFromLparam(lparam);
            if (!global.tracking_mouse) {
                var track: win32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = .{ .LEAVE = 1 },
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (0 == win32.TrackMouseEvent(&track)) win32.panicWin32("TrackMouseEvent", win32.GetLastError());
                global.tracking_mouse = true;
            }
            app.onMouse(.{ .x = p.x, .y = p.y });
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            global.tracking_mouse = false;
            app.onMouse(null);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub const Painter = struct {
    hdc: win32.HDC,

    pub fn fill(p: *const Painter, r: layout.Rect, rgb: layout.Rgb) void {
        const brush = win32.createSolidBrush(colorref(rgb));
        defer win32.deleteObject(brush);
        win32.fillRect(p.hdc, .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom }, brush);
    }

    pub fn text(p: *const Painter, utf8: []const u8, r: layout.Rect, rgb: layout.Rgb) void {
        var wide: [layout.max_text_len]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(&wide, utf8) catch {
            std.log.err("text is not valid WTF-8: '{s}'", .{utf8});
            return;
        };
        if (win32.CLR_INVALID == win32.SetTextColor(p.hdc, colorref(rgb))) win32.panicWin32("SetTextColor", win32.GetLastError());
        var rect: win32.RECT = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
        if (0 == win32.DrawTextW(p.hdc, @ptrCast(&wide), @intCast(len), &rect, .{
            .SINGLELINE = 1,
            .VCENTER = 1,
            .END_ELLIPSIS = 1,
            .NOPREFIX = 1,
        })) win32.panicWin32("DrawText", win32.GetLastError());
    }
};

fn colorref(rgb: layout.Rgb) u32 {
    return @as(u32, rgb.r) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");
const appdata = mutiny.appdata;

const app = @import("app.zig");
const layout = @import("layout.zig");
