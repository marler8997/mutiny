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
            stub_image: dotnet.MonoImageOpenStatus,
            stub_assembly: dotnet.MonoImageOpenStatus,
            stub_class,
            stub_method: [:0]const u8,
        },
    },
    loaded: struct {
        dll_string: [:0]const u16,
        module: win32.HINSTANCE,
        loop: PlayerLoop,
    },
};

const PlayerLoop = struct {
    funcs: MonoFuncs,
    update: *const dotnet.Method,
    on_gui: *const dotnet.Method,
    ticks: u64 = 0,
    stopped: ?struct { method: []const u8, exception: [*:0]const u8 } = null,
};

const tick_timer_id = 1;
const tick_ms = 16;
const ticks_per_repaint = 60;

pub export fn wWinMain(
    hInstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    pCmdLine: [*:0]u16,
    nCmdShow: u32,
) callconv(.winapi) c_int {
    _ = pCmdLine;
    _ = nCmdShow;

    global.mono_state = initMono();

    const CLASS_NAME = win32.L("UnityWndClass");
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
    if (global.mono_state == .loaded) {
        if (0 == win32.SetTimer(hwnd, tick_timer_id, tick_ms, null)) win32.panicWin32("SetTimer", win32.GetLastError());
    }
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
        win32.WM_TIMER => {
            if (wParam == tick_timer_id) tick(hwnd);
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
                        .stub_image => |status| lineOutFmt(hdc, row, "opening the UnityEngine.CoreModule stub image failed: {t}", .{status}),
                        .stub_assembly => |status| lineOutFmt(hdc, row, "loading the UnityEngine.CoreModule stub assembly failed: {t}", .{status}),
                        .stub_class => lineOut(hdc, row, "the UnityEngine.CoreModule stub has no TestPlayerLoop class"),
                        .stub_method => |name| lineOutFmt(hdc, row, "TestPlayerLoop has no {s} method", .{name}),
                    }
                    lineOutFmt(hdc, row + 1, "DLL '{f}'", .{fmtW(f.dll_string)});
                },
                .loaded => |loaded| {
                    lineOut(hdc, row, "Mono Loaded.");
                    lineOutFmt(hdc, row + 1, "DLL '{f}'", .{fmtW(loaded.dll_string)});
                    if (loaded.loop.stopped) |stopped| {
                        lineOutFmt(hdc, row + 2, "player loop stopped after {} ticks: {s} threw {s}", .{ loaded.loop.ticks, stopped.method, stopped.exception });
                    } else {
                        lineOutFmt(hdc, row + 2, "player loop: {} ticks", .{loaded.loop.ticks});
                    }
                },
            }
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn tick(hwnd: win32.HWND) void {
    const loop = switch (global.mono_state) {
        .loaded => |*loaded| &loaded.loop,
        else => return,
    };
    if (loop.stopped != null) return;
    const calls = [_]struct { name: []const u8, method: *const dotnet.Method }{
        .{ .name = "Update", .method = loop.update },
        .{ .name = "OnGUI", .method = loop.on_gui },
    };
    for (calls) |call| {
        var exception: ?*const dotnet.Object = null;
        _ = loop.funcs.runtime_invoke(call.method, null, null, &exception);
        if (exception) |e| {
            const class_name = loop.funcs.class_get_name(loop.funcs.object_get_class(e));
            std.log.err("TestPlayerLoop.{s} threw {s}, the player loop is stopped", .{ call.name, class_name });
            loop.stopped = .{ .method = call.name, .exception = class_name };
            if (0 == win32.KillTimer(hwnd, tick_timer_id)) win32.panicWin32("KillTimer", win32.GetLastError());
            invalidate(hwnd);
            return;
        }
    }
    loop.ticks += 1;
    if (loop.ticks % ticks_per_repaint == 0) invalidate(hwnd);
}

fn invalidate(hwnd: win32.HWND) void {
    if (0 == win32.InvalidateRect(hwnd, null, 1)) win32.panicWin32("InvalidateRect", win32.GetLastError());
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

const MonoFuncs = struct {
    class_from_name: *const dotnet.shared.class_from_name,
    class_get_method_from_name: *const dotnet.shared.class_get_method_from_name,
    class_get_name: *const dotnet.shared.class_get_name,
    object_get_class: *const dotnet.shared.object_get_class,
    runtime_invoke: *const dotnet.shared.runtime_invoke,
    mono: struct {
        jit_init: *const dotnet.mono.jit_init,
        set_assemblies_path: *const dotnet.mono.set_assemblies_path,
        image_open_from_data: *const dotnet.mono.image_open_from_data,
        assembly_load_from: *const dotnet.mono.assembly_load_from,
    },
};

const unity_core_stub_dll = @embedFile("unity_core_stub_dll");

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
    const funcs = dotnetload.resolveOnly(MonoFuncs, .mono, module, &missing_proc) catch return .{ .init_failed = .{
        .dll_string = dll.load_string,
        .module = module,
        .reason = .{ .proc_not_found = missing_proc },
    } };

    const repo_managed = repo_game_dir ++ "\\REPO_Data\\Managed";
    switch (dll.kind) {
        .name => {},
        .repo_game => {
            funcs.mono.set_assemblies_path(repo_managed);
        },
    }

    std.log.info("mono_jit_init...", .{});
    const domain = funcs.mono.jit_init("TestGameDomain") orelse {
        std.log.err("mono_jit_init failed", .{});
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .mono_jit_init } };
    };
    std.log.info("Mono domain created: 0x{x}", .{@intFromPtr(domain)});

    var status: dotnet.MonoImageOpenStatus = .ok;
    const image = funcs.mono.image_open_from_data(
        unity_core_stub_dll.ptr,
        @intCast(unity_core_stub_dll.len),
        1,
        &status,
    ) orelse return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .{ .stub_image = status } } };
    if (status != .ok) return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .{ .stub_image = status } } };
    _ = funcs.mono.assembly_load_from(image, "UnityEngine.CoreModule", &status) orelse
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .{ .stub_assembly = status } } };
    if (status != .ok) return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .{ .stub_assembly = status } } };
    std.log.info("loaded the embedded UnityEngine.CoreModule stub ({} bytes)", .{unity_core_stub_dll.len});

    const loop_class = funcs.class_from_name(image, "UnityEngine", "TestPlayerLoop") orelse
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .stub_class } };
    const update = funcs.class_get_method_from_name(loop_class, "Update", 0) orelse
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .{ .stub_method = "Update" } } };
    const on_gui = funcs.class_get_method_from_name(loop_class, "OnGUI", 0) orelse
        return .{ .init_failed = .{ .dll_string = dll.load_string, .module = module, .reason = .{ .stub_method = "OnGUI" } } };

    return .{ .loaded = .{
        .dll_string = dll.load_string,
        .module = module,
        .loop = .{ .funcs = funcs, .update = update, .on_gui = on_gui },
    } };
}

const std = @import("std");
const win32 = @import("win32").everything;
const fmtW = std.unicode.fmtUtf16Le;
const dotnet = @import("dotnet.zig");
const dotnetload = @import("dotnetload.zig");
