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
    var d2d_factory: *win32.ID2D1Factory = undefined;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    var d2d_store: D2d = undefined;
    var d2d: ?*D2d = null;
    var text_format: ?struct { dpi: u32, format: *win32.IDWriteTextFormat } = null;
};

const window_class_name = win32.L("MutinyMainWindow");
const window_title = win32.L(app.title);

pub fn main() void {
    if (@intFromPtr(std.os.windows.peb().ProcessParameters.hStdError) == 0) {
        const localappdata = appdata.get() orelse std.debug.panic("no LOCALAPPDATA environment variable", .{});
        var path_buf: [appdata.max_path]u16 = undefined;
        const path = switch (appdata.format(&path_buf, localappdata, &.{ win32.L("mutiny"), win32.L("gui.log") })) {
            .ok => |p| p,
            .too_long => std.debug.panic("LOCALAPPDATA ({} chars) is too long", .{localappdata.len}),
        };
        if (appdata.makeDirs(&path_buf, appdata.parentDirLen(path))) |err| win32.panicWin32("CreateDirectory", err);
        const handle = win32.CreateFileW(
            path,
            .{ .FILE_APPEND_DATA = 1 },
            .{ .READ = 1 },
            null,
            .OPEN_ALWAYS,
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(gui.log)", win32.GetLastError());
        if (0 == win32.SetStdHandle(win32.STD_ERROR_HANDLE, handle)) win32.panicWin32("SetStdHandle", win32.GetLastError());
        var time: win32.SYSTEMTIME = undefined;
        win32.GetLocalTime(&time);
        std.log.info("started {}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2}, stderr is this file", .{
            time.wYear, time.wMonth,  time.wDay,
            time.wHour, time.wMinute, time.wSecond,
        });
    }

    {
        var awareness: win32.PROCESS_DPI_AWARENESS = undefined;
        const hr = win32.GetProcessDpiAwareness(null, &awareness);
        if (hr < 0) std.debug.panic("GetProcessDpiAwareness failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
        switch (awareness) {
            .PER_MONITOR_DPI_AWARE => {},
            else => |a| std.debug.panic("the process is {t}, the manifest should make it PER_MONITOR_DPI_AWARE", .{a}),
        }
    }

    {
        const hr = win32.D2D1CreateFactory(.SINGLE_THREADED, win32.IID_ID2D1Factory, null, @ptrCast(&global.d2d_factory));
        if (hr < 0) win32.panicHresult("D2D1CreateFactory", hr);
    }
    {
        const hr = win32.DWriteCreateFactory(.SHARED, win32.IID_IDWriteFactory, @ptrCast(&global.dwrite_factory));
        if (hr < 0) win32.panicHresult("DWriteCreateFactory", hr);
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

pub fn captureMouse(capture: bool) void {
    if (capture) {
        _ = win32.SetCapture(global.hwnd);
    } else if (0 == win32.ReleaseCapture()) win32.panicWin32("ReleaseCapture", win32.GetLastError());
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
            _, const ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const size = win32.getClientSize(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);

            const d2d: *D2d = global.d2d orelse blk: {
                var target: *win32.ID2D1HwndRenderTarget = undefined;
                const target_props: win32.D2D1_RENDER_TARGET_PROPERTIES = .{
                    .type = .DEFAULT,
                    .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .PREMULTIPLIED },
                    .dpiX = 0,
                    .dpiY = 0,
                    .usage = .{},
                    .minLevel = .DEFAULT,
                };
                const hwnd_props: win32.D2D1_HWND_RENDER_TARGET_PROPERTIES = .{
                    .hwnd = hwnd,
                    .pixelSize = .{ .width = @intCast(size.cx), .height = @intCast(size.cy) },
                    .presentOptions = .{},
                };
                {
                    const hr = global.d2d_factory.CreateHwndRenderTarget(&target_props, &hwnd_props, &target);
                    if (hr < 0) win32.panicHresult("CreateHwndRenderTarget", hr);
                }
                target.ID2D1RenderTarget.SetDpi(96, 96);
                var brush: *win32.ID2D1SolidColorBrush = undefined;
                {
                    const black: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
                    const hr = target.ID2D1RenderTarget.CreateSolidColorBrush(&black, null, &brush);
                    if (hr < 0) win32.panicHresult("CreateSolidColorBrush", hr);
                }
                global.d2d_store = .{ .target = target, .brush = brush };
                global.d2d = &global.d2d_store;
                break :blk &global.d2d_store;
            };

            const text_format = blk: {
                if (global.text_format) |cached| {
                    if (cached.dpi == dpi) break :blk cached.format;
                    _ = cached.format.IUnknown.Release();
                    global.text_format = null;
                }
                var format: *win32.IDWriteTextFormat = undefined;
                {
                    const size_px: f32 = @as(f32, layout.font_points) * @as(f32, @floatFromInt(dpi)) / 72.0;
                    const hr = global.dwrite_factory.CreateTextFormat(
                        win32.L("Segoe UI"),
                        null,
                        win32.DWRITE_FONT_WEIGHT_NORMAL,
                        win32.DWRITE_FONT_STYLE_NORMAL,
                        win32.DWRITE_FONT_STRETCH_NORMAL,
                        size_px,
                        win32.L(""),
                        &format,
                    );
                    if (hr < 0) win32.panicHresult("CreateTextFormat", hr);
                }
                {
                    const hr = format.SetParagraphAlignment(.CENTER);
                    if (hr < 0) win32.panicHresult("SetParagraphAlignment", hr);
                }
                {
                    const hr = format.SetWordWrapping(.NO_WRAP);
                    if (hr < 0) win32.panicHresult("SetWordWrapping", hr);
                }
                {
                    var ellipsis: *win32.IDWriteInlineObject = undefined;
                    const create_hr = global.dwrite_factory.CreateEllipsisTrimmingSign(format, &ellipsis);
                    if (create_hr < 0) win32.panicHresult("CreateEllipsisTrimmingSign", create_hr);
                    defer _ = ellipsis.IUnknown.Release();
                    const trimming: win32.DWRITE_TRIMMING = .{ .granularity = .CHARACTER, .delimiter = 0, .delimiterCount = 0 };
                    const hr = format.SetTrimming(&trimming, ellipsis);
                    if (hr < 0) win32.panicHresult("SetTrimming", hr);
                }
                global.text_format = .{ .dpi = dpi, .format = format };
                break :blk format;
            };

            {
                const pixel_size: win32.D2D_SIZE_U = .{ .width = @intCast(size.cx), .height = @intCast(size.cy) };
                const hr = d2d.target.Resize(&pixel_size);
                if (hr < 0) win32.panicHresult("Resize", hr);
            }

            const target = &d2d.target.ID2D1RenderTarget;
            target.BeginDraw();
            const painter: Painter = .{ .target = target, .brush = d2d.brush, .text_format = text_format };
            app.onPaint(&painter, .{ .x = size.cx, .y = size.cy }, dpiScale(dpi));
            const hr = target.EndDraw(null, null);
            if (hr == win32.D2DERR_RECREATE_TARGET) {
                std.log.info("D2DERR_RECREATE_TARGET", .{});
                _ = d2d.brush.IUnknown.Release();
                _ = d2d.target.IUnknown.Release();
                global.d2d = null;
                win32.invalidateHwnd(hwnd);
            } else if (hr < 0) win32.panicHresult("EndDraw", hr);
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
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => {
            const p = win32.pointFromLparam(lparam);
            app.onMouseButton(.left, if (msg == win32.WM_LBUTTONDOWN) .down else .up, .{ .x = p.x, .y = p.y });
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(win32.hiword(wparam));
            app.onWheel(@as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(win32.WHEEL_DELTA)));
            return 0;
        },
        win32.WM_KEYDOWN => {
            const key: ?layout.Key = switch (@as(win32.VIRTUAL_KEY, @enumFromInt(wparam))) {
                win32.VK_UP => .up,
                win32.VK_DOWN => .down,
                win32.VK_PRIOR => .page_up,
                win32.VK_NEXT => .page_down,
                win32.VK_HOME => .home,
                win32.VK_END => .end,
                else => null,
            };
            if (key) |k| app.onKey(k);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const D2d = struct {
    target: *win32.ID2D1HwndRenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
};

pub const Painter = struct {
    target: *const win32.ID2D1RenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    text_format: *win32.IDWriteTextFormat,

    fn setColor(p: *const Painter, rgb: layout.Rgb) *win32.ID2D1Brush {
        const color: win32.D2D_COLOR_F = .{
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = 1,
        };
        p.brush.SetColor(&color);
        return &p.brush.ID2D1Brush;
    }

    pub fn fill(p: *const Painter, r: layout.Rect, rgb: layout.Rgb) void {
        p.target.FillRectangle(&rectF(r), p.setColor(rgb));
    }

    pub fn text(p: *const Painter, utf8: []const u8, r: layout.Rect, rgb: layout.Rgb) void {
        var wide: [layout.max_text_len + 1]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(wide[0..layout.max_text_len], utf8) catch {
            std.log.err("text is not valid WTF-8: '{s}'", .{utf8});
            return;
        };
        wide[len] = 0;
        p.target.DrawText(wide[0..len :0], @intCast(len), p.text_format, &rectF(r), p.setColor(rgb), .{}, .NATURAL);
    }

    pub fn pushClip(p: *const Painter, r: layout.Rect) void {
        p.target.PushAxisAlignedClip(&rectF(r), .ALIASED);
    }

    pub fn popClip(p: *const Painter) void {
        p.target.PopAxisAlignedClip();
    }
};

fn rectF(r: layout.Rect) win32.D2D_RECT_F {
    return .{
        .left = @floatFromInt(r.left),
        .top = @floatFromInt(r.top),
        .right = @floatFromInt(r.right),
        .bottom = @floatFromInt(r.bottom),
    };
}

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");
const appdata = mutiny.appdata;

const app = @import("app.zig");
const layout = @import("layout.zig");
