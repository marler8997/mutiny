const global = struct {
    pub var mono: Mono = .uninitialized;
};

const Mono = union(enum) {
    uninitialized,
    mod_not_found,
    init_failed: struct {
        dll_string: [:0]const u16,
        module: win32.HINSTANCE,
        reason: union(enum) {
            proc_not_found: [:0]const u8,
            mono_jit_init,
        },
    },
    loaded: struct {
        dll_string: [:0]const u16,
        module: win32.HINSTANCE,
    },
};

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

    global.mono = initMono();

    const CLASS_NAME = win32.L("TestGameWindow");
    const wc = win32.WNDCLASSW{
        .style = .{},
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
    };
    if (0 == win32.RegisterClassW(&wc))
        win32.panicWin32("RegisterClass", win32.GetLastError());

    const hwnd = win32.CreateWindowExW(
        .{},
        CLASS_NAME,
        win32.L("Test Game"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT, // Position
        800,
        300, // Size
        null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null, // Additional application data
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });
    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    return @intCast(msg.wParam);
}

fn WindowProc(hwnd: win32.HWND, msg: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            const hdc, const ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);
            win32.fillRect(hdc, ps.rcPaint, @ptrFromInt(@intFromEnum(win32.COLOR_WINDOW) + 1));

            var y: i32 = 20;
            win32.textOutA(hdc, 20, y, "TestGame with Mono Runtime");
            y += 25;
            switch (global.mono) {
                .uninitialized => {
                    lineOut(hdc, 0, "Mono not initialized.");
                },
                .mod_not_found => {
                    lineOut(hdc, 0, "Mono module not found.");
                    lineOut(hdc, 1, "Make sure mono-2.0-bdwgc.dll is in the same directory or in PATH.");
                },
                .init_failed => |f| {
                    switch (f.reason) {
                        .proc_not_found => |name| lineOutFmt(hdc, 0, "mono missing function '{s}'", .{name}),
                        .mono_jit_init => lineOut(hdc, 0, "mono_jit_init failed"),
                    }
                    lineOutFmt(hdc, 1, "DLL '{f}'", .{fmtW(f.dll_string)});
                },
                .loaded => |loaded| {
                    lineOut(hdc, 0, "Mono Loaded.");
                    lineOutFmt(hdc, 1, "DLL '{f}'", .{fmtW(loaded.dll_string)});
                },
            }
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wParam, lParam);
}

const margin = 5;
const line_height = 18;

fn lineOut(hdc: win32.HDC, row: i32, str: []const u8) void {
    win32.textOutA(hdc, margin, margin + row * line_height, str);
}
fn lineOutFmt(hdc: win32.HDC, row: i32, comptime fmt: []const u8, args: anytype) void {
    var text_buf: [1000]u8 = undefined;
    lineOut(hdc, row, std.fmt.bufPrint(&text_buf, fmt, args) catch @panic("string too long"));
}

const MonoDomain = opaque {};

const MonoFuncs = struct {
    jit_init: *const fn ([*:0]const u8) callconv(.c) ?*MonoDomain,
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!MonoFuncs {
        return MonoFuncs{
            .jit_init = try maybeGetMonoProc(proc_ref, mod, fn ([*:0]const u8) callconv(.c) ?*MonoDomain, "mono_jit_init"),
        };
    }
    fn maybeGetMonoProc(proc_ref: *[:0]const u8, module: win32.HINSTANCE, comptime T: type, name: [:0]const u8) error{ProcNotFound}!*const T {
        proc_ref.* = name;
        return getMonoProc(module, T, name);
    }
};

fn getMonoProc(module: win32.HINSTANCE, comptime T: type, name: [:0]const u8) error{ProcNotFound}!*const T {
    return @ptrCast(win32.GetProcAddress(module, name) orelse switch (win32.GetLastError()) {
        .ERROR_PROC_NOT_FOUND => return error.ProcNotFound,
        else => |e| std.debug.panic("GetProcAddress '{s}' with mono DLL failed, error={f}", .{ name, e }),
    });
}

fn initMono() Mono {
    const MonoDll = struct {
        kind: enum { name, repo_game },
        load_string: [:0]const u16,
    };
    const mono_dlls = [_]MonoDll{
        // .{ .kind = .name, .load_string = win32.L("mono-2.0-bdwgc.dll") },
        // win32.L("mono.dll"),
        // win32.L("mono-2.0-sgen.dll"),
        .{ .kind = .repo_game, .load_string = win32.L(
            "C:\\Program Files (x86)\\Steam\\steamapps\\common\\REPO\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll",
        ) },
    };

    const dll, const module: win32.HINSTANCE = blk: {
        for (mono_dlls) |dll| {
            std.log.info("attempting to load '{f}'", .{fmtW(dll.load_string)});
            if (win32.LoadLibraryW(dll.load_string)) |module| break :blk .{ dll, module };
            switch (win32.GetLastError()) {
                .ERROR_MOD_NOT_FOUND => {},
                else => |e| std.debug.panic(
                    "LoadLibrary '{f}' failed, error={f}",
                    .{ fmtW(dll.load_string), e },
                ),
            }
        } else return .mod_not_found;
    };
    std.log.info("successfully loaded '{f}'", .{fmtW(dll.load_string)});

    switch (dll.kind) {
        .name => {},
        .repo_game => {
            const name = "mono_set_assemblies_path";
            const mono_set_assemblies_path = getMonoProc(
                module,
                fn ([*:0]const u8) callconv(.c) void,
                name,
            ) catch return .{ .init_failed = .{
                .dll_string = dll.load_string,
                .module = module,
                .reason = .{ .proc_not_found = name },
            } };
            mono_set_assemblies_path("C:\\Program Files (x86)\\Steam\\steamapps\\common\\REPO\\REPO_Data\\Managed");
        },
    }

    var missing_proc: [:0]const u8 = undefined;
    const funcs = MonoFuncs.init(&missing_proc, module) catch return .{ .init_failed = .{
        .dll_string = dll.load_string,
        .module = module,
        .reason = .{ .proc_not_found = missing_proc },
    } };

    std.log.info("mono_jit_init...", .{});
    const domain = funcs.jit_init("TestGameDomain") orelse {
        std.log.err("mono_jit_init failed", .{});
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .mono_jit_init } };
    };
    std.log.info("Mono domain created: 0x{x}", .{@intFromPtr(domain)});
    return .{ .loaded = .{ .dll_string = dll.load_string, .module = module } };
}

const std = @import("std");
const win32 = @import("win32").everything;
const fmtW = std.unicode.fmtUtf16Le;
