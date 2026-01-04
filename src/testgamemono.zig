const global = struct {
    pub var mono_state: MonoState = .uninitialized;
};

const MonoState = union(enum) {
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

    global.mono_state = initMono();

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

            var row: i32 = 0;
            lineOutFmt(hdc, row, "PID {}", .{win32.GetCurrentProcessId()});
            row += 1;
            switch (global.mono_state) {
                .uninitialized => {
                    lineOut(hdc, row, "Mono not initialized.");
                },
                .mod_not_found => {
                    lineOut(hdc, row, "Mono module not found.");
                    lineOut(hdc, row + 1, "Make sure mono-2.0-bdwgc.dll is in the same directory or in PATH.");
                },
                .init_failed => |f| {
                    switch (f.reason) {
                        .proc_not_found => |name| lineOutFmt(hdc, row, "mono missing function '{s}'", .{name}),
                        .mono_jit_init => lineOut(hdc, row, "mono_jit_init failed"),
                    }
                    lineOutFmt(hdc, row + 1, "DLL '{f}'", .{fmtW(f.dll_string)});
                },
                .loaded => |loaded| {
                    lineOut(hdc, row, "Mono Loaded.");
                    lineOutFmt(hdc, row + 1, "DLL '{f}'", .{fmtW(loaded.dll_string)});
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
const MonoAssembly = opaque {};

const DotnetFuncs = struct {
    jit_init: *const fn ([*:0]const u8) callconv(.c) ?*MonoDomain,
    set_assemblies_path: *const fn ([*:0]const u8) callconv(.c) void,
    domain_assembly_open: *const fn (*MonoDomain, [*:0]const u8) callconv(.c) ?*MonoAssembly,
    pub fn init(mod: win32.HINSTANCE, proc_ref: *[:0]const u8) error{ProcNotFound}!DotnetFuncs {
        return DotnetFuncs{
            .jit_init = try dotnetload.get(mod, .jit_init, proc_ref),
            .set_assemblies_path = try dotnetload.get(mod, .set_assemblies_path, proc_ref),
            .domain_assembly_open = try dotnetload.get(mod, .domain_assembly_open, proc_ref),
        };
    }
};

fn initMono() MonoState {
    const MonoDll = struct {
        kind: enum { name, repo_game },
        load_string: [:0]const u16,
    };

    const repo_game_dir = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\REPO";

    const mono_dlls = [_]MonoDll{
        // .{ .kind = .name, .load_string = win32.L("mono-2.0-bdwgc.dll") },
        // win32.L("mono.dll"),
        // win32.L("mono-2.0-sgen.dll"),
        .{ .kind = .repo_game, .load_string = win32.L(
            repo_game_dir ++ "\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll",
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

    var missing_proc: [:0]const u8 = undefined;
    const funcs = DotnetFuncs.init(module, &missing_proc) catch return .{ .init_failed = .{
        .dll_string = dll.load_string,
        .module = module,
        .reason = .{ .proc_not_found = missing_proc },
    } };

    const repo_managed = repo_game_dir ++ "\\REPO_Data\\Managed";
    switch (dll.kind) {
        .name => {},
        .repo_game => {
            funcs.set_assemblies_path(repo_managed);
        },
    }

    std.log.info("mono_jit_init...", .{});
    const domain = funcs.jit_init("TestGameDomain") orelse {
        std.log.err("mono_jit_init failed", .{});
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .mono_jit_init } };
    };
    std.log.info("Mono domain created: 0x{x}", .{@intFromPtr(domain)});

    if (funcs.domain_assembly_open(domain, "System.dll")) |assembly| {
        _ = assembly;
        std.log.info("System.dll: loaded", .{});
    } else {
        std.log.info("System.dll: not loaded", .{});
    }

    switch (dll.kind) {
        .name => {},
        .repo_game => {
            const repo_extra_dlls = [_][]const u8{
                "Assembly-CSharp.dll",
                "Facepunch.Steamworks.Win64.dll",
            };
            inline for (repo_extra_dlls) |sub_path| {
                const filename = repo_managed ++ "\\" ++ sub_path;
                if (funcs.domain_assembly_open(domain, filename)) |assembly| {
                    _ = assembly;
                    std.log.info("{s}: loaded", .{sub_path});
                } else {
                    std.log.info("{s}: not loaded", .{sub_path});
                }
            }
        },
    }

    return .{ .loaded = .{ .dll_string = dll.load_string, .module = module } };
}

const std = @import("std");
const win32 = @import("win32").everything;
const fmtW = std.unicode.fmtUtf16Le;
const dotnetload = @import("dotnetload.zig").template(DotnetFuncs);
