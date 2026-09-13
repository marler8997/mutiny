pub const panic = win32.messageBoxThenPanic(.{ .title = "Mutiny Panic!", .style = .{ .ICONHAND = 1 } });

const global = struct {
    var hwnd: win32.HWND = undefined;
    var tracking_mouse = false;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    var wic_factory: *win32.IWICImagingFactory = undefined;
    var d2d: ?D2d = null;
    var target_generation: u32 = 0;
    var text_formats: ?TextFormats = null;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var dll_path: []const u8 = undefined;
    var exit_waits: std.ArrayListUnmanaged(ExitWait) = .empty;
    var wm_shellhook: u32 = undefined;
    var wm_attached: u32 = undefined;
    var apps_dir_path_buf: [mutiny.appdata.max_path * 3]u8 = undefined;
    var apps_dir_path: []const u8 = undefined;
    var agent_prompt_path: []const u8 = undefined;
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
    const name_need = std.unicode.calcWtf8Len(name_w);
    if (name_need > name_buf.len) {
        std.log.err("pid {} exe name is {} bytes, too long", .{ pid, name_need });
        return;
    }
    const name_len = std.unicode.wtf16LeToWtf8(&name_buf, name_w);

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
    {
        const exe_dir = std.fs.selfExeDirPathAlloc(global.arena.allocator()) catch |err| std.debug.panic("finding my own directory failed: {t}", .{err});
        global.agent_prompt_path = std.fs.path.join(global.arena.allocator(), &.{ exe_dir, "mutiny-agent.md" }) catch |e| std.debug.panic("{t}", .{e});
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
    const style_ex: win32.WINDOW_EX_STYLE = .{ .NOREDIRECTIONBITMAP = 1 };
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
    setWindowIcons(hwnd, win32.dpiFromHwnd(hwnd));

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

    paint(hwnd);
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

pub const max_title_len = 128;

pub fn setTitle(comptime fmt: []const u8, args: anytype) void {
    var utf8: [max_title_len * 4]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => &utf8,
    };
    var wide: [max_title_len + 1]u16 = undefined;
    if (0 == win32.SetWindowTextW(global.hwnd, layout.toWide(text, &wide))) win32.panicWin32("SetWindowText", win32.GetLastError());
}

pub fn agentPromptPath() []const u8 {
    return global.agent_prompt_path;
}

pub fn askSavePath(dir: []const u8, title: []const u8, buf: []u8) ?[]const u8 {
    var dialog: *win32.IFileSaveDialog = undefined;
    {
        const hr = win32.CoCreateInstance(win32.CLSID_FileSaveDialog, null, win32.CLSCTX_INPROC_SERVER, win32.IID_IFileSaveDialog, @ptrCast(&dialog));
        if (hr < 0) win32.panicHresult("CoCreateInstance(FileSaveDialog)", hr);
    }
    defer _ = dialog.IUnknown.Release();
    {
        const hr = dialog.IFileDialog.SetOptions(.{ .OVERWRITEPROMPT = 1, .NOCHANGEDIR = 1, .PATHMUSTEXIST = 1 });
        if (hr < 0) win32.panicHresult("IFileDialog.SetOptions", hr);
    }
    {
        var title_w: [max_title_len + 1]u16 = undefined;
        const hr = dialog.IFileDialog.SetTitle(layout.toWide(title, &title_w));
        if (hr < 0) win32.panicHresult("IFileDialog.SetTitle", hr);
    }
    {
        var dir_w: [max_exepath + 2]u16 = undefined;
        const dir_z = layout.toWide(dir, &dir_w);
        var folder: *win32.IShellItem = undefined;
        const hr = win32.SHCreateItemFromParsingName(dir_z, null, win32.IID_IShellItem, @ptrCast(&folder));
        if (hr < 0) {
            std.log.err("SHCreateItemFromParsingName '{s}' failed, hresult=0x{x}", .{ dir, @as(u32, @bitCast(hr)) });
            return null;
        }
        defer _ = folder.IUnknown.Release();
        const set_hr = dialog.IFileDialog.SetFolder(folder);
        if (set_hr < 0) win32.panicHresult("IFileDialog.SetFolder", set_hr);
    }
    {
        const hr = dialog.IFileDialog.IModalWindow.Show(global.hwnd);
        if (hr == @as(win32.HRESULT, @bitCast(@as(u32, 0x800704C7)))) return null;
        if (hr < 0) win32.panicHresult("IFileDialog.Show", hr);
    }
    var item: ?*win32.IShellItem = null;
    {
        const hr = dialog.IFileDialog.GetResult(&item);
        if (hr < 0) win32.panicHresult("IFileDialog.GetResult", hr);
    }
    defer _ = item.?.IUnknown.Release();
    var name: ?win32.PWSTR = null;
    {
        const hr = item.?.GetDisplayName(win32.SIGDN_FILESYSPATH, &name);
        if (hr < 0) win32.panicHresult("IShellItem.GetDisplayName", hr);
    }
    defer win32.CoTaskMemFree(name);
    const wide = std.mem.span(name.?);
    const need = std.unicode.calcWtf8Len(wide);
    if (need > buf.len) {
        std.log.err("the chosen path is {} bytes, too long", .{need});
        return null;
    }
    return buf[0..std.unicode.wtf16LeToWtf8(buf, wide)];
}

pub const ClipboardText = struct {
    handle: isize,
    buf: []u16,

    pub fn alloc(units: usize) ?ClipboardText {
        const handle = win32.GlobalAlloc(win32.GMEM_MOVEABLE, units * 2);
        if (handle == 0) {
            std.log.err("GlobalAlloc failed, error={f}", .{win32.GetLastError()});
            return null;
        }
        const ptr: [*]u16 = @ptrCast(@alignCast(win32.GlobalLock(handle) orelse {
            std.log.err("GlobalLock failed, error={f}", .{win32.GetLastError()});
            globalFree(handle);
            return null;
        }));
        return .{ .handle = handle, .buf = ptr[0..units] };
    }

    pub fn discard(text: ClipboardText) void {
        globalUnlock(text.handle);
        globalFree(text.handle);
    }

    pub fn commit(text: ClipboardText) void {
        globalUnlock(text.handle);
        if (0 == win32.OpenClipboard(global.hwnd)) {
            std.log.err("OpenClipboard failed, error={f}", .{win32.GetLastError()});
            globalFree(text.handle);
            return;
        }
        defer if (0 == win32.CloseClipboard()) win32.panicWin32("CloseClipboard", win32.GetLastError());
        if (0 == win32.EmptyClipboard()) {
            std.log.err("EmptyClipboard failed, error={f}", .{win32.GetLastError()});
            globalFree(text.handle);
            return;
        }
        if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), @ptrFromInt(@as(usize, @bitCast(text.handle)))) == null) {
            std.log.err("SetClipboardData failed, error={f}", .{win32.GetLastError()});
            globalFree(text.handle);
        }
    }
};

fn globalUnlock(handle: isize) void {
    if (0 == win32.GlobalUnlock(handle)) switch (win32.GetLastError()) {
        .NO_ERROR => {},
        else => |err| win32.panicWin32("GlobalUnlock", err),
    };
}

fn globalFree(handle: isize) void {
    if (0 != win32.GlobalFree(handle)) win32.panicWin32("GlobalFree", win32.GetLastError());
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

fn setWindowIcons(hwnd: win32.HWND, dpi: u32) void {
    const hinstance = win32.GetModuleHandleW(null);
    const sizes = [_]struct { which: u32, metric: i32 }{
        .{ .which = win32.ICON_SMALL, .metric = @intFromEnum(win32.SM_CXSMICON) },
        .{ .which = win32.ICON_BIG, .metric = @intFromEnum(win32.SM_CXICON) },
    };
    for (sizes) |size| {
        const px = win32.GetSystemMetricsForDpi(size.metric, dpi);
        const icon = win32.LoadImageW(hinstance, @ptrFromInt(1), .ICON, px, px, win32.LR_SHARED) orelse
            win32.panicWin32("LoadImage(icon)", win32.GetLastError());
        _ = win32.SendMessageW(hwnd, win32.WM_SETICON, size.which, @bitCast(@intFromPtr(icon)));
    }
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_PAINT => {
            paint(hwnd);
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
            setWindowIcons(hwnd, win32.loword(wparam));
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

fn paint(hwnd: win32.HWND) void {
    _, const ps = win32.beginPaint(hwnd);
    defer win32.endPaint(hwnd, &ps);

    const size = win32.getClientSize(hwnd);
    const dpi = win32.dpiFromHwnd(hwnd);

    const d2d: *D2d = if (global.d2d) |*d| d else blk: {
        global.d2d = D2d.init(hwnd);
        global.target_generation += 1;
        break :blk &global.d2d.?;
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

    const dc = d2d.beginFrame(size);
    const target = &dc.ID2D1RenderTarget;
    const painter: Painter = .{ .target = target, .brush = d2d.brush, .text_formats = text_formats };
    app.onPaint(&painter, .{ .x = size.cx, .y = size.cy }, dpiScale(dpi));
    d2d.endFrame() catch |err| switch (err) {
        error.RecreateTarget => {
            std.log.info("the render device was lost, recreating it", .{});
            d2d.deinit();
            global.d2d = null;
            win32.invalidateHwnd(hwnd);
        },
    };
}

const D2d = struct {
    d3d_device: *win32.ID3D11Device,
    d2d_device: *win32.ID2D1Device,
    res_dc: *win32.ID2D1DeviceContext,
    dcomp: *win32.IDCompositionDesktopDevice,
    target: *win32.IDCompositionTarget,
    visual: *win32.IDCompositionVisual2,
    brush: *win32.ID2D1SolidColorBrush,
    surface: ?*win32.IDCompositionSurface = null,
    surface_size: win32.D2D_SIZE_U = .{ .width = 0, .height = 0 },
    frame_dc: ?*win32.ID2D1DeviceContext = null,

    fn init(hwnd: win32.HWND) D2d {
        var d3d_device: *win32.ID3D11Device = undefined;
        {
            const hr = win32.D3D11CreateDevice(
                null,
                win32.D3D_DRIVER_TYPE_HARDWARE,
                null,
                win32.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                null,
                0,
                win32.D3D11_SDK_VERSION,
                &d3d_device,
                null,
                null,
            );
            if (hr < 0) win32.panicHresult("D3D11CreateDevice", hr);
        }
        var dxgi_device: *win32.IDXGIDevice = undefined;
        {
            const hr = d3d_device.IUnknown.QueryInterface(win32.IID_IDXGIDevice, @ptrCast(&dxgi_device));
            if (hr < 0) win32.panicHresult("QueryInterface(IDXGIDevice)", hr);
        }
        defer _ = dxgi_device.IUnknown.Release();
        var d2d_device: *win32.ID2D1Device = undefined;
        {
            const hr = win32.D2D1CreateDevice(dxgi_device, null, @ptrCast(&d2d_device));
            if (hr < 0) win32.panicHresult("D2D1CreateDevice", hr);
        }
        var res_dc: *win32.ID2D1DeviceContext = undefined;
        {
            const hr = d2d_device.CreateDeviceContext(win32.D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &res_dc);
            if (hr < 0) win32.panicHresult("CreateDeviceContext", hr);
        }
        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const black: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
            const hr = res_dc.ID2D1RenderTarget.CreateSolidColorBrush(&black, null, &brush);
            if (hr < 0) win32.panicHresult("CreateSolidColorBrush", hr);
        }
        var dcomp: *win32.IDCompositionDesktopDevice = undefined;
        {
            const hr = win32.DCompositionCreateDevice2(&d2d_device.IUnknown, win32.IID_IDCompositionDesktopDevice, @ptrCast(&dcomp));
            if (hr < 0) win32.panicHresult("DCompositionCreateDevice2", hr);
        }
        var target: *win32.IDCompositionTarget = undefined;
        {
            const hr = dcomp.CreateTargetForHwnd(hwnd, 1, @ptrCast(&target));
            if (hr < 0) win32.panicHresult("CreateTargetForHwnd", hr);
        }
        var visual: *win32.IDCompositionVisual2 = undefined;
        {
            const hr = dcomp.IDCompositionDevice2.CreateVisual(@ptrCast(&visual));
            if (hr < 0) win32.panicHresult("CreateVisual", hr);
        }
        {
            const hr = target.SetRoot(&visual.IDCompositionVisual);
            if (hr < 0) win32.panicHresult("SetRoot", hr);
        }
        return .{
            .d3d_device = d3d_device,
            .d2d_device = d2d_device,
            .res_dc = res_dc,
            .dcomp = dcomp,
            .target = target,
            .visual = visual,
            .brush = brush,
        };
    }

    fn deinit(d2d: *D2d) void {
        if (d2d.surface) |s| _ = s.IUnknown.Release();
        _ = d2d.visual.IUnknown.Release();
        _ = d2d.target.IUnknown.Release();
        _ = d2d.dcomp.IUnknown.Release();
        _ = d2d.brush.IUnknown.Release();
        _ = d2d.res_dc.IUnknown.Release();
        _ = d2d.d2d_device.IUnknown.Release();
        _ = d2d.d3d_device.IUnknown.Release();
        d2d.* = undefined;
    }

    fn ensureSurface(d2d: *D2d, size: win32.D2D_SIZE_U) void {
        if (d2d.surface != null and d2d.surface_size.width == size.width and d2d.surface_size.height == size.height) return;
        if (d2d.surface) |s| {
            _ = s.IUnknown.Release();
            d2d.surface = null;
        }
        var surface: *win32.IDCompositionSurface = undefined;
        {
            const hr = d2d.dcomp.IDCompositionDevice2.CreateSurface(
                size.width,
                size.height,
                win32.DXGI_FORMAT_B8G8R8A8_UNORM,
                win32.DXGI_ALPHA_MODE_PREMULTIPLIED,
                @ptrCast(&surface),
            );
            if (hr < 0) win32.panicHresult("CreateSurface", hr);
        }
        {
            const hr = d2d.visual.IDCompositionVisual.SetContent(&surface.IUnknown);
            if (hr < 0) win32.panicHresult("SetContent", hr);
        }
        d2d.surface = surface;
        d2d.surface_size = size;
    }

    fn beginFrame(d2d: *D2d, client: win32.SIZE) *win32.ID2D1DeviceContext {
        d2d.ensureSurface(.{ .width = @intCast(@max(client.cx, 1)), .height = @intCast(@max(client.cy, 1)) });
        var dc: *win32.ID2D1DeviceContext = undefined;
        var offset: win32.POINT = undefined;
        {
            const hr = d2d.surface.?.BeginDraw(null, win32.IID_ID2D1DeviceContext, @ptrCast(&dc), &offset);
            if (hr < 0) win32.panicHresult("IDCompositionSurface.BeginDraw", hr);
        }
        dc.ID2D1RenderTarget.SetDpi(96, 96);
        dc.ID2D1RenderTarget.SetTextAntialiasMode(.GRAYSCALE);
        const translate: win32.D2D_MATRIX_3X2_F = .{ .Anonymous = .{ .Anonymous1 = .{
            .m11 = 1,
            .m12 = 0,
            .m21 = 0,
            .m22 = 1,
            .dx = @floatFromInt(offset.x),
            .dy = @floatFromInt(offset.y),
        } } };
        dc.ID2D1RenderTarget.SetTransform(&translate);
        d2d.frame_dc = dc;
        return dc;
    }

    fn endFrame(d2d: *D2d) error{RecreateTarget}!void {
        if (d2d.frame_dc) |dc| {
            _ = dc.IUnknown.Release();
            d2d.frame_dc = null;
        }
        {
            const hr = d2d.surface.?.EndDraw();
            if (hr == win32.D2DERR_RECREATE_TARGET or hr == win32.DXGI_ERROR_DEVICE_REMOVED) return error.RecreateTarget;
            if (hr < 0) win32.panicHresult("IDCompositionSurface.EndDraw", hr);
        }
        {
            const hr = d2d.dcomp.IDCompositionDevice2.Commit();
            if (hr < 0) win32.panicHresult("Commit", hr);
        }
    }
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

    pub fn clear(p: *const Painter, rgb: layout.Rgb, alpha: f32) void {
        const color: win32.D2D_COLOR_F = .{
            .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
            .a = alpha,
        };
        p.target.Clear(&color);
    }

    pub fn text(p: *const Painter, utf8: []const u8, r: layout.Rect, rgb: layout.Rgb, alignment: layout.TextAlign) void {
        var buf: [layout.max_text_len + 1]u16 = undefined;
        const wide = layout.toWide(utf8, &buf);
        const format = switch (alignment) {
            .left => p.text_formats.left,
            .center => p.text_formats.center,
        };
        p.target.DrawText(wide, @intCast(wide.len), format, &rectF(r), p.setColor(rgb), .{}, .NATURAL);
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
const layout = @import("layout");
