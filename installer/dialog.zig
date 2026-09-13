pub const Line = struct {
    text: []const u8,
    muted: bool = false,
};

pub const Button = struct {
    label: []const u8,
    style: enum { primary, normal, danger },
};

pub const Spec = struct {
    title: []const u8,
    lines: []const Line,
    checkbox: ?[]const u8 = null,
    buttons: []const Button,
};

pub const Result = struct {
    button: ?usize,
    checked: bool,
};

const max_lines = 6;
const max_buttons = 3;

const points = struct {
    const width = 460;
    const margin = 16;
    const icon = 32;
    const gap = 10;
    const line_height = 20;
    const button_width = 130;
    const button_height = 28;
    const check = 16;
};

const class_name = win32.L("MutinySetupDialog");
const window_title = win32.L("Mutiny Setup");

const global = struct {
    var spec: Spec = undefined;
    var checked = false;
    var result: ?usize = null;
    var done = false;
    var hover: ?usize = null;
    var tracking_mouse = false;
    var class_registered = false;
    var font: ?win32.HFONT = null;
    var font_dpi: u32 = 0;
};

pub fn show(spec: Spec) Result {
    std.debug.assert(spec.lines.len <= max_lines);
    std.debug.assert(spec.buttons.len >= 1 and spec.buttons.len <= max_buttons);
    global.spec = spec;
    global.checked = false;
    global.result = null;
    global.done = false;
    global.hover = null;

    const hinstance = win32.GetModuleHandleW(null);
    if (!global.class_registered) {
        const wc: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = win32.LoadIconW(hinstance, @ptrFromInt(1)),
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&wc)) win32.panicWin32("RegisterClassEx", win32.GetLastError());
        global.class_registered = true;
    }

    const style: win32.WINDOW_STYLE = @bitCast(@as(u32, @bitCast(win32.WS_CAPTION)) | @as(u32, @bitCast(win32.WS_SYSMENU)));
    const style_ex: win32.WINDOW_EX_STYLE = .{};
    const hwnd = win32.CreateWindowExW(
        style_ex,
        class_name,
        window_title,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        0,
        0,
        null,
        null,
        hinstance,
        null,
    ) orelse win32.panicWin32("CreateWindowEx", win32.GetLastError());
    defer _ = win32.DestroyWindow(hwnd);

    {
        const dark: win32.BOOL = 1;
        _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));
    }
    place(hwnd, win32.dpiFromHwnd(hwnd));
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    var msg: win32.MSG = undefined;
    while (!global.done) {
        const got = win32.GetMessageW(&msg, null, 0, 0);
        if (got <= 0) break;
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    return .{ .button = global.result, .checked = global.checked };
}

fn frameSize(dpi: u32) win32.SIZE {
    const l = layoutFor(global.spec, dpi);
    var frame: win32.RECT = .{ .left = 0, .top = 0, .right = l.client.cx, .bottom = l.client.cy };
    const style: win32.WINDOW_STYLE = @bitCast(@as(u32, @bitCast(win32.WS_CAPTION)) | @as(u32, @bitCast(win32.WS_SYSMENU)));
    if (0 == win32.AdjustWindowRectExForDpi(&frame, style, 0, .{}, dpi)) win32.panicWin32("AdjustWindowRectExForDpi", win32.GetLastError());
    return .{ .cx = frame.right - frame.left, .cy = frame.bottom - frame.top };
}

fn place(hwnd: win32.HWND, dpi: u32) void {
    const size = frameSize(dpi);
    const width = size.cx;
    const height = size.cy;
    var work: win32.RECT = undefined;
    if (0 == win32.SystemParametersInfoW(win32.SPI_GETWORKAREA, 0, &work, .{})) win32.panicWin32("SystemParametersInfo", win32.GetLastError());
    const x = work.left + @divTrunc(work.right - work.left - width, 2);
    const y = work.top + @divTrunc(work.bottom - work.top - height, 2);
    if (0 == win32.SetWindowPos(hwnd, null, x, y, width, height, .{ .NOZORDER = 1, .NOACTIVATE = 1 })) win32.panicWin32("SetWindowPos", win32.GetLastError());
}

fn scale(value: i32, dpi: u32) i32 {
    return @divTrunc(value * @as(i32, @intCast(dpi)) + 48, 96);
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) win32.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn contains(r: win32.RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

const Layout = struct {
    client: win32.SIZE,
    icon: win32.RECT,
    title: win32.RECT,
    lines: [max_lines]win32.RECT,
    checkbox: win32.RECT,
    check_label: win32.RECT,
    buttons: [max_buttons]win32.RECT,
};

fn layoutFor(spec: Spec, dpi: u32) Layout {
    const margin = scale(points.margin, dpi);
    const icon = scale(points.icon, dpi);
    const gap = scale(points.gap, dpi);
    const line_height = scale(points.line_height, dpi);
    const button_width = scale(points.button_width, dpi);
    const button_height = scale(points.button_height, dpi);
    const check = scale(points.check, dpi);
    const width = scale(points.width, dpi);

    var l: Layout = undefined;
    l.icon = rect(margin, margin, margin + icon, margin + icon);
    l.title = rect(margin + icon + gap, margin, width - margin, margin + icon);
    var y = margin + icon + gap;
    for (spec.lines, 0..) |_, i| {
        l.lines[i] = rect(margin, y, width - margin, y + line_height);
        y += line_height;
    }
    if (spec.checkbox != null) {
        y += gap;
        const inset = @divTrunc(line_height - check, 2);
        l.checkbox = rect(margin, y + inset, margin + check, y + inset + check);
        l.check_label = rect(margin + check + gap, y, width - margin, y + line_height);
        y += line_height;
    }
    y += gap * 2;
    const count: i32 = @intCast(spec.buttons.len);
    var x = width - margin - count * button_width - (count - 1) * gap;
    for (spec.buttons, 0..) |_, i| {
        l.buttons[i] = rect(x, y, x + button_width, y + button_height);
        x += button_width + gap;
    }
    y += button_height + margin;
    l.client = .{ .cx = width, .cy = y };
    return l;
}

fn colorref(rgb: layout.Rgb) u32 {
    return @as(u32, rgb.r) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}

fn fill(hdc: win32.HDC, r: win32.RECT, rgb: layout.Rgb) void {
    const brush = win32.CreateSolidBrush(colorref(rgb)) orelse win32.panicWin32("CreateSolidBrush", win32.GetLastError());
    defer _ = win32.DeleteObject(brush);
    _ = win32.FillRect(hdc, &r, brush);
}

fn text(hdc: win32.HDC, utf8: []const u8, r: win32.RECT, rgb: layout.Rgb, center: bool) void {
    var buf: [layout.max_text_len + 1]u16 = undefined;
    const wide = layout.toWide(utf8, &buf) catch |err| switch (err) {
        error.InvalidWtf8 => {
            std.log.err("text is not valid WTF-8: '{s}'", .{utf8});
            return;
        },
    };
    _ = win32.SetTextColor(hdc, colorref(rgb));
    var bounds = r;
    _ = win32.DrawTextW(hdc, wide, @intCast(wide.len), &bounds, .{
        .SINGLELINE = 1,
        .VCENTER = 1,
        .END_ELLIPSIS = 1,
        .NOPREFIX = 1,
        .CENTER = @intFromBool(center),
    });
}

fn font(dpi: u32) win32.HFONT {
    if (global.font) |f| {
        if (global.font_dpi == dpi) return f;
        _ = win32.DeleteObject(f);
        global.font = null;
    }
    const f = win32.CreateFontW(
        @divTrunc(-scale(layout.font_points * 96, dpi), 72),
        0,
        0,
        0,
        @intCast(win32.FW_NORMAL),
        0,
        0,
        0,
        win32.DEFAULT_CHARSET,
        win32.OUT_DEFAULT_PRECIS,
        win32.CLIP_DEFAULT_PRECIS,
        win32.CLEARTYPE_QUALITY,
        .DONTCARE,
        win32.L("Segoe UI"),
    ) orelse win32.panicWin32("CreateFont", win32.GetLastError());
    global.font = f;
    global.font_dpi = dpi;
    return f;
}

fn paint(hwnd: win32.HWND) void {
    const hdc, const ps = win32.beginPaint(hwnd);
    defer win32.endPaint(hwnd, &ps);
    const dpi = win32.dpiFromHwnd(hwnd);
    const spec = global.spec;
    const l = layoutFor(spec, dpi);
    const size = win32.getClientSize(hwnd);

    fill(hdc, rect(0, 0, size.cx, size.cy), layout.color.window);
    _ = win32.SetBkMode(hdc, .TRANSPARENT);
    const old_font = win32.SelectObject(hdc, font(dpi));
    defer _ = win32.SelectObject(hdc, old_font);

    const icon_size = l.icon.right - l.icon.left;
    if (win32.LoadImageW(win32.GetModuleHandleW(null), @ptrFromInt(1), .ICON, icon_size, icon_size, win32.LR_SHARED)) |icon| {
        _ = win32.DrawIconEx(hdc, l.icon.left, l.icon.top, @ptrCast(icon), icon_size, icon_size, 0, null, win32.DI_NORMAL);
    }
    text(hdc, spec.title, l.title, layout.color.name, false);
    for (spec.lines, 0..) |line, i| {
        text(hdc, line.text, l.lines[i], if (line.muted) layout.color.muted else layout.color.text, false);
    }
    if (spec.checkbox) |label| {
        fill(hdc, l.checkbox, layout.color.button);
        if (global.checked) {
            const inset = scale(3, dpi);
            fill(hdc, rect(l.checkbox.left + inset, l.checkbox.top + inset, l.checkbox.right - inset, l.checkbox.bottom - inset), layout.color.accent);
        }
        text(hdc, label, l.check_label, layout.color.text, false);
    }
    for (spec.buttons, 0..) |button, i| {
        const hot = global.hover == i;
        const back, const ink = switch (button.style) {
            .primary => .{ if (hot) layout.color.accent_hover else layout.color.accent, layout.color.accent_ink },
            .normal => .{ if (hot) layout.color.button_hover else layout.color.button, layout.color.text },
            .danger => .{ if (hot) layout.color.failed_hover else layout.color.failed, layout.color.bad },
        };
        fill(hdc, l.buttons[i], back);
        text(hdc, button.label, l.buttons[i], ink, true);
    }
}

fn hitButton(hwnd: win32.HWND, x: i32, y: i32) ?usize {
    const l = layoutFor(global.spec, win32.dpiFromHwnd(hwnd));
    for (global.spec.buttons, 0..) |_, i| if (contains(l.buttons[i], x, y)) return i;
    return null;
}

fn hitCheckbox(hwnd: win32.HWND, x: i32, y: i32) bool {
    if (global.spec.checkbox == null) return false;
    const l = layoutFor(global.spec, win32.dpiFromHwnd(hwnd));
    return contains(l.checkbox, x, y) or contains(l.check_label, x, y);
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_MOUSEMOVE => {
            if (!global.tracking_mouse) {
                var track: win32.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(win32.TRACKMOUSEEVENT), .dwFlags = .{ .LEAVE = 1 }, .hwndTrack = hwnd, .dwHoverTime = 0 };
                if (0 != win32.TrackMouseEvent(&track)) global.tracking_mouse = true;
            }
            const hover = hitButton(hwnd, win32.xFromLparam(lparam), win32.yFromLparam(lparam));
            if (hover != global.hover) {
                global.hover = hover;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            global.tracking_mouse = false;
            if (global.hover != null) {
                global.hover = null;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const x = win32.xFromLparam(lparam);
            const y = win32.yFromLparam(lparam);
            if (hitButton(hwnd, x, y)) |i| {
                global.result = i;
                global.done = true;
            } else if (hitCheckbox(hwnd, x, y)) {
                global.checked = !global.checked;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_KEYDOWN => {
            switch (@as(win32.VIRTUAL_KEY, @enumFromInt(wparam))) {
                win32.VK_ESCAPE => global.done = true,
                win32.VK_RETURN => {
                    global.result = 0;
                    global.done = true;
                },
                else => {},
            }
            return 0;
        },
        win32.WM_CLOSE => {
            global.done = true;
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            size.* = frameSize(@intCast(wparam));
            return 1;
        },
        win32.WM_DPICHANGED => {
            const dpi: u32 = win32.hiword(wparam);
            const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const expected = frameSize(dpi);
            if (expected.cx != suggested.right - suggested.left or expected.cy != suggested.bottom - suggested.top) std.debug.panic(
                "WM_DPICHANGED to {} suggested {}x{} but WM_GETDPISCALEDSIZE asked for {}x{}",
                .{ dpi, suggested.right - suggested.left, suggested.bottom - suggested.top, expected.cx, expected.cy },
            );
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
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const std = @import("std");
const win32 = @import("win32").everything;
const layout = @import("layout");
