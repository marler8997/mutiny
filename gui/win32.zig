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
    var wic_factory: *win32.IWICImagingFactory = undefined;
    var d2d_store: D2d = undefined;
    var d2d: ?*D2d = null;
    var target_generation: u32 = 0;
    var text_formats: ?TextFormats = null;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var dll_path: []const u8 = undefined;
    var exit_waits: std.ArrayListUnmanaged(ExitWait) = .empty;
    var wm_shellhook: u32 = undefined;
    var wm_attached: u32 = undefined;
    var apps_dir_path_buf: [mutiny.appdata.max_path * 3]u8 = undefined;
    var apps_dir_path: []const u8 = undefined;
};

const TextFormats = struct {
    dpi: u32,
    left: *win32.IDWriteTextFormat,
    center: *win32.IDWriteTextFormat,
};

fn createTextFormat(dpi: u32, alignment: win32.DWRITE_TEXT_ALIGNMENT) *win32.IDWriteTextFormat {
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
        const hr = format.SetTextAlignment(alignment);
        if (hr < 0) win32.panicHresult("SetTextAlignment", hr);
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
    return format;
}

const wm_attach_done = win32.WM_APP + 1;

const wm_game_exited = win32.WM_APP + 2;

const ExitWait = struct {
    pid: u32,
    process: win32.HANDLE,
    wait: win32.HANDLE,
};

fn reportGame(pid: u32) void {
    for (global.exit_waits.items) |wait| if (wait.pid == pid) return;

    var path_buf: [mutiny.scan.max_exe_path:0]u16 = undefined;
    const path = mutiny.scan.exePath(pid, &path_buf) orelse return;
    const name_w = mutiny.getname.fromExe(path) catch |err| {
        std.log.err("pid {} has an unusable exe path '{f}': {t}", .{ pid, std.unicode.fmtUtf16Le(path), err });
        return;
    };
    var name_buf: [layout.max_game_name * 3]u8 = undefined;
    const name_len = std.unicode.calcWtf8Len(name_w);
    if (name_len > name_buf.len) {
        std.log.err("pid {} exe name is {} bytes, too long", .{ pid, name_len });
        return;
    }
    std.debug.assert(name_len == std.unicode.wtf16LeToWtf8(&name_buf, name_w));

    const process = win32.OpenProcess(.{ .SYNCHRONIZE = 1 }, 0, pid) orelse {
        std.log.err("OpenProcess(SYNCHRONIZE) pid {} failed, error={f}", .{ pid, win32.GetLastError() });
        return;
    };
    var wait: ?win32.HANDLE = null;
    if (0 == win32.RegisterWaitForSingleObject(&wait, process, exitCallback, @ptrFromInt(pid), win32.INFINITE, win32.WT_EXECUTEONLYONCE)) {
        std.log.err("RegisterWaitForSingleObject pid {} failed, error={f}", .{ pid, win32.GetLastError() });
        win32.closeHandle(process);
        return;
    }
    global.exit_waits.append(std.heap.smp_allocator, .{ .pid = pid, .process = process, .wait = wait.? }) catch |err| {
        std.log.err("out of memory tracking pid {}: {t}", .{ pid, err });
        return;
    };

    app.onGameWindowCreated(pid, name_buf[0..name_len], switch (mutiny.scan.status(pid)) {
        .not_attached => .not_attached,
        .attached => .attached,
        .unresponsive => .unresponsive,
    });
}

fn exitCallback(context: ?*anyopaque, timed_out: win32.BOOLEAN) callconv(.winapi) void {
    _ = timed_out;
    const pid: u32 = @intCast(@intFromPtr(context));
    if (0 == win32.PostMessageW(global.hwnd, wm_game_exited, pid, 0)) win32.panicWin32(
        "PostMessage(game exited)",
        win32.GetLastError(),
    );
}

pub fn attach(pid: u32) void {
    const thread = std.Thread.spawn(.{}, attachThread, .{pid}) catch |err| {
        std.log.err("cannot start the attach thread for pid {}: {t}", .{ pid, err });
        app.onAttachDone(pid, false);
        return;
    };
    thread.detach();
}

fn attachThread(pid: u32) void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const success = if (mutiny.injector.attach(arena_instance.allocator(), global.dll_path, pid)) true else |err| blk: {
        if (err != error.Reported) std.log.err("attach to pid {} failed: {t}", .{ pid, err });
        break :blk false;
    };
    if (0 == win32.PostMessageW(global.hwnd, wm_attach_done, pid, @intFromBool(success))) win32.panicWin32(
        "PostMessage(attach done)",
        win32.GetLastError(),
    );
}

pub const max_exepath = mutiny.appdata.max_exepath;

const wm_launch_done = win32.WM_APP + 3;

const LaunchArgs = struct {
    id: u32,
    exe_buf: [mutiny.appdata.max_exepath]u8,
    exe_len: usize,
};

pub fn launch(id: u32, exe: []const u8) void {
    var args: LaunchArgs = .{ .id = id, .exe_buf = undefined, .exe_len = exe.len };
    @memcpy(args.exe_buf[0..exe.len], exe);
    const thread = std.Thread.spawn(.{}, launchThread, .{args}) catch |err| {
        std.log.err("cannot start the launch thread for '{s}': {t}", .{ exe, err });
        app.onLaunchDone(id, false);
        return;
    };
    thread.detach();
}

fn launchThread(args: LaunchArgs) void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const exe = args.exe_buf[0..args.exe_len];
    const success = if (mutiny.injector.startExe(arena_instance.allocator(), global.dll_path, exe)) true else |err| blk: {
        if (err != error.Reported) std.log.err("launch '{s}' failed: {t}", .{ exe, err });
        break :blk false;
    };
    if (0 == win32.PostMessageW(global.hwnd, wm_launch_done, args.id, @intFromBool(success))) win32.panicWin32(
        "PostMessage(launch done)",
        win32.GetLastError(),
    );
}

const window_class_name = win32.L("MutinyMainWindow");
const window_title = win32.L(app.title);

pub fn main() void {
    if (@intFromPtr(std.os.windows.peb().ProcessParameters.hStdError) == 0) {
        const localappdata = mutiny.appdata.get() orelse std.debug.panic("no LOCALAPPDATA environment variable", .{});
        var path_buf: [mutiny.appdata.max_path]u16 = undefined;
        const path = switch (mutiny.appdata.format(&path_buf, localappdata, &.{ win32.L("mutiny"), win32.L("gui.log") })) {
            .ok => |p| p,
            .too_long => std.debug.panic("LOCALAPPDATA ({} chars) is too long", .{localappdata.len}),
        };
        if (mutiny.appdata.makeDirs(&path_buf, mutiny.appdata.parentDirLen(path))) |err| win32.panicWin32("CreateDirectory", err);
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
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
        if (hr < 0) win32.panicHresult("CoInitializeEx", hr);
    }
    {
        const hr = win32.CoCreateInstance(
            &win32.CLSID_WICImagingFactory,
            null,
            win32.CLSCTX_INPROC_SERVER,
            win32.IID_IWICImagingFactory,
            @ptrCast(&global.wic_factory),
        );
        if (hr < 0) win32.panicHresult("CoCreateInstance(WICImagingFactory)", hr);
    }

    var apps_path_buf: [mutiny.appdata.max_path]u16 = undefined;
    const apps_path = blk: {
        const localappdata = mutiny.appdata.get() orelse std.debug.panic("no LOCALAPPDATA environment variable", .{});
        const path = switch (mutiny.appdata.format(
            &apps_path_buf,
            localappdata,
            &.{ win32.L("mutiny"), win32.L("app") },
        )) {
            .ok => |p| p,
            .too_long => std.debug.panic("LOCALAPPDATA ({} chars) is too long", .{localappdata.len}),
        };
        if (mutiny.appdata.makeDirs(&apps_path_buf, path.len)) |err| win32.panicWin32("CreateDirectory", err);
        const utf8_len = std.unicode.wtf16LeToWtf8(&global.apps_dir_path_buf, path);
        global.apps_dir_path = global.apps_dir_path_buf[0..utf8_len];
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
    global.dll_path = mutiny.injector.findDll(global.arena.allocator(), "dll") catch |err| switch (err) {
        error.Reported => std.debug.panic("Mutiny.dll is not beside this exe, see the log", .{}),
        else => |e| std.debug.panic("finding Mutiny.dll failed: {t}", .{e}),
    };

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
        const dark: win32.BOOL = 1;
        const hr = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark,
            @sizeOf(win32.BOOL),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute(dark mode) failed, hresult=0x{x}",
            .{@as(u32, @bitCast(hr))},
        );
    }

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

    global.wm_shellhook = win32.RegisterWindowMessageW(win32.L("SHELLHOOK"));
    if (global.wm_shellhook == 0) win32.panicWin32("RegisterWindowMessage(SHELLHOOK)", win32.GetLastError());
    global.wm_attached = win32.RegisterWindowMessageW(mutiny.mutinyipc.attached_broadcast_message);
    if (global.wm_attached == 0) win32.panicWin32("RegisterWindowMessage(MutinyAttached)", win32.GetLastError());
    if (0 == win32.RegisterShellHookWindow(hwnd)) win32.panicWin32("RegisterShellHookWindow", win32.GetLastError());

    {
        const games = mutiny.scan.unityGames(global.arena.allocator()) catch |err| switch (err) {
            error.Reported => &.{},
            else => |e| std.debug.panic("scanning for Unity windows failed: {t}", .{e}),
        };
        for (games) |game| reportGame(game.pid);
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

pub fn appsDirPath() []const u8 {
    return global.apps_dir_path;
}

pub fn openDirectory(path: []const u8) void {
    shellOpen(null, path);
}

pub fn openTextFile(path: []const u8) void {
    shellOpen(win32.L("notepad.exe"), path);
}

fn shellOpen(program: ?[*:0]const u16, path: []const u8) void {
    var wide: [mutiny.appdata.max_path * 2 + 1]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(wide[0 .. wide.len - 1], path) catch |err| {
        std.log.err("cannot open '{s}': {t}", .{ path, err });
        return;
    };
    wide[len] = 0;
    const path_z = wide[0..len :0];
    const result = win32.ShellExecuteW(
        null,
        win32.L("open"),
        program orelse path_z,
        if (program == null) null else path_z,
        null,
        @bitCast(win32.SW_SHOWNORMAL),
    );
    if (@intFromPtr(result) <= 32) std.log.err("ShellExecute '{s}' failed with {}", .{ path, @intFromPtr(result) });
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
                global.target_generation += 1;
                break :blk &global.d2d_store;
            };

            const text_formats: *const TextFormats = blk: {
                if (global.text_formats) |*cached| {
                    if (cached.dpi == dpi) break :blk cached;
                    _ = cached.left.IUnknown.Release();
                    _ = cached.center.IUnknown.Release();
                    global.text_formats = null;
                }
                global.text_formats = .{
                    .dpi = dpi,
                    .left = createTextFormat(dpi, .LEADING),
                    .center = createTextFormat(dpi, .CENTER),
                };
                break :blk &global.text_formats.?;
            };

            {
                const pixel_size: win32.D2D_SIZE_U = .{ .width = @intCast(size.cx), .height = @intCast(size.cy) };
                const hr = d2d.target.Resize(&pixel_size);
                if (hr < 0) win32.panicHresult("Resize", hr);
            }

            const target = &d2d.target.ID2D1RenderTarget;
            target.BeginDraw();
            const painter: Painter = .{ .target = target, .brush = d2d.brush, .text_formats = text_formats };
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
        wm_attach_done => {
            app.onAttachDone(@intCast(wparam), lparam != 0);
            return 0;
        },
        wm_launch_done => {
            app.onLaunchDone(@intCast(wparam), lparam != 0);
            return 0;
        },
        wm_game_exited => {
            const pid: u32 = @intCast(wparam);
            for (global.exit_waits.items, 0..) |wait, index| {
                if (wait.pid != pid) continue;
                if (0 == win32.UnregisterWaitEx(wait.wait, null)) switch (win32.GetLastError()) {
                    .ERROR_IO_PENDING => {},
                    else => |e| win32.panicWin32("UnregisterWaitEx", e),
                };
                win32.closeHandle(wait.process);
                _ = global.exit_waits.swapRemove(index);
                break;
            }
            app.onGameExited(pid);
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
                win32.VK_ESCAPE => .escape,
                else => null,
            };
            if (key) |k| app.onKey(k);
            return 0;
        },
        else => if (msg == global.wm_shellhook) {
            if (wparam == win32.HSHELL_WINDOWCREATED) {
                const created: win32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (mutiny.scan.isUnityWindow(created)) {
                    var pid: u32 = undefined;
                    if (0 != win32.GetWindowThreadProcessId(created, &pid)) reportGame(pid);
                }
            }
            return 0;
        } else if (msg == global.wm_attached) {
            app.onGameAttached(@intCast(wparam));
            return 0;
        } else return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const D2d = struct {
    target: *win32.ID2D1HwndRenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
};

pub const Painter = struct {
    target: *const win32.ID2D1RenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    text_formats: *const TextFormats,

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

    pub fn text(p: *const Painter, utf8: []const u8, r: layout.Rect, rgb: layout.Rgb, alignment: layout.TextAlign) void {
        var wide: [layout.max_text_len + 1]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(wide[0..layout.max_text_len], utf8) catch {
            std.log.err("text is not valid WTF-8: '{s}'", .{utf8});
            return;
        };
        wide[len] = 0;
        const format = switch (alignment) {
            .left => p.text_formats.left,
            .center => p.text_formats.center,
        };
        p.target.DrawText(wide[0..len :0], @intCast(len), format, &rectF(r), p.setColor(rgb), .{}, .NATURAL);
    }

    pub fn pushClip(p: *const Painter, r: layout.Rect) void {
        p.target.PushAxisAlignedClip(&rectF(r), .ALIASED);
    }

    pub fn popClip(p: *const Painter) void {
        p.target.PopAxisAlignedClip();
    }

    pub fn drawIcon(p: *const Painter, icon: *Icon, r: layout.Rect) void {
        if (icon.d2d == null or icon.generation != global.target_generation) {
            if (icon.d2d) |old| _ = old.IUnknown.Release();
            var bitmap: *win32.ID2D1Bitmap = undefined;
            const hr = p.target.CreateBitmapFromWicBitmap(&icon.source.IWICBitmapSource, null, &bitmap);
            if (hr < 0) win32.panicHresult("CreateBitmapFromWicBitmap", hr);
            icon.d2d = bitmap;
            icon.generation = global.target_generation;
        }
        p.target.DrawBitmap(icon.d2d.?, &rectF(r), 1.0, .LINEAR, null);
    }
};

pub const Icon = struct {
    source: *win32.IWICFormatConverter,
    d2d: ?*win32.ID2D1Bitmap = null,
    generation: u32 = 0,

    pub fn load(exe: []const u8, size: u32) ?Icon {
        var wide: [mutiny.appdata.max_exepath + 1]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(wide[0..mutiny.appdata.max_exepath], exe) catch |err| {
            std.log.err("exe path is not valid WTF-8 '{s}': {t}", .{ exe, err });
            return null;
        };
        wide[len] = 0;
        var maybe_hicon: ?win32.HICON = null;
        {
            const hr = win32.SHDefExtractIconW(wide[0..len :0], 0, 0, &maybe_hicon, null, size);
            if (hr == win32.S_FALSE) {
                std.log.info("'{s}' has no icon", .{exe});
                return null;
            }
            if (hr < 0) {
                std.log.err("SHDefExtractIcon for '{s}' (size {}) failed, hresult=0x{x}", .{ exe, size, @as(u32, @bitCast(hr)) });
                return null;
            }
        }
        const hicon = maybe_hicon orelse {
            std.log.err("SHDefExtractIcon for '{s}' returned S_OK with no icon", .{exe});
            return null;
        };
        defer if (0 == win32.DestroyIcon(hicon)) win32.panicWin32("DestroyIcon", win32.GetLastError());

        var bitmap: ?*win32.IWICBitmap = null;
        {
            const hr = global.wic_factory.CreateBitmapFromHICON(hicon, &bitmap);
            if (hr < 0) win32.panicHresult("CreateBitmapFromHICON", hr);
        }
        defer _ = bitmap.?.IUnknown.Release();

        var converter: ?*win32.IWICFormatConverter = null;
        {
            const hr = global.wic_factory.CreateFormatConverter(&converter);
            if (hr < 0) win32.panicHresult("CreateFormatConverter", hr);
        }
        {
            const hr = converter.?.Initialize(
                &bitmap.?.IWICBitmapSource,
                @constCast(&win32.GUID_WICPixelFormat32bppPBGRA),
                .itmapDitherTypeNone,
                null,
                0,
                .itmapPaletteTypeCustom,
            );
            if (hr < 0) win32.panicHresult("IWICFormatConverter.Initialize", hr);
        }
        return .{ .source = converter.? };
    }

    pub fn deinit(icon: *Icon) void {
        if (icon.d2d) |bitmap| _ = bitmap.IUnknown.Release();
        _ = icon.source.IUnknown.Release();
        icon.* = undefined;
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

const app = @import("app.zig");
const layout = @import("layout.zig");
