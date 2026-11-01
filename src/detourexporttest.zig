// Calls DetourInstall in a built Mutiny.dll, looked up by name the way a mod does. It starts with
// nothing attached, so the export has to answer not_ready. Then it attaches for real to a window of its
// own, which makes this the main thread, and checks the other answers.
const attach_timeout_ms = 10000;

var install: detour.DetourInstallFunction = undefined;

const Function = *const fn (usize) callconv(.c) usize;
var original: Function = undefined;
fn hook(v: usize) callconv(.c) usize {
    return original(v) + 1000;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

// Attaching writes under LOCALAPPDATA, so point it somewhere that isn't the real Mutiny install.
fn redirectAppData() void {
    var path: [win32.MAX_PATH + 1]u16 = undefined;
    const len = win32.GetTempPathW(path.len, @ptrCast(&path));
    if (len == 0 or len >= path.len) die("GetTempPath failed, error={f}", .{win32.GetLastError()});
    if (win32.SetEnvironmentVariableW(win32.L("LOCALAPPDATA"), @ptrCast(&path)) == 0)
        die("SetEnvironmentVariable failed, error={f}", .{win32.GetLastError()});
}

// 14 nops, then: mov rax, rcx; ret
fn allocIdentity() Function {
    const mem = win32.VirtualAlloc(null, 4096, .{ .COMMIT = 1, .RESERVE = 1 }, win32.PAGE_EXECUTE_READWRITE) orelse
        die("VirtualAlloc failed, error={f}", .{win32.GetLastError()});
    const code: [*]u8 = @ptrCast(mem);
    @memset(code[0..14], 0x90);
    @memcpy(code[14..18], &[_]u8{ 0x48, 0x89, 0xc8, 0xc3 });
    return @ptrCast(code);
}

fn expectCall(function: Function, want: usize, what: []const u8) void {
    const got = function(5);
    if (got != want) die("{s} returned {} instead of {}", .{ what, got, want });
}

fn expectResult(got: detour.DetourInstallResult, want: detour.DetourInstallResult, what: []const u8) void {
    if (got != want) die("{s} answered {t} instead of {t}", .{ what, got, want });
}

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const args = try std.process.argsAlloc(arena_instance.allocator());
    if (args.len != 2) die("expected 1 cmdline arg, the path to Mutiny.dll, but got {}", .{args.len - 1});
    redirectAppData();

    const module = dynlib.load(args[1]) catch |e| die("loading '{s}' failed with {t}", .{ args[1], e });
    install = @ptrCast(dynlib.getProc(module, "DetourInstall") catch |e| die("finding DetourInstall failed with {t}", .{e}));
    const attach: win32.LPTHREAD_START_ROUTINE = @ptrCast(dynlib.getProc(module, "MutinyAttach") catch |e|
        die("finding MutinyAttach failed with {t}", .{e}));

    // Nothing has attached: not ready, without touching anything.
    const untouched = 0x1234;
    var trampoline: usize = untouched;
    expectResult(install(0, 0, &trampoline), .not_ready, "before attaching it");
    if (trampoline != untouched) die("not ready wrote the trampoline 0x{x}", .{trampoline});

    // Attach to a window on this thread, and retry the way a mod would until it stops saying not ready.
    const hinstance = win32.GetModuleHandleW(null);
    const window_class: win32.WNDCLASSW = .{
        .style = .{},
        .lpfnWndProc = win32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = win32.L("UnityWndClass"),
    };
    if (win32.RegisterClassW(&window_class) == 0) die("RegisterClass failed, error={f}", .{win32.GetLastError()});
    if (win32.CreateWindowExW(
        .{},
        win32.L("UnityWndClass"),
        win32.L("detourexporttest"),
        .{},
        0,
        0,
        1,
        1,
        null,
        null,
        hinstance,
        null,
    ) == null) die("CreateWindow failed, error={f}", .{win32.GetLastError()});
    if (win32.CreateThread(null, 0, attach, @ptrFromInt(attach_timeout_ms), .{}, null) == null)
        die("CreateThread failed, error={f}", .{win32.GetLastError()});

    const target = allocIdentity();
    var waited_ms: u32 = 0;
    while (true) : (waited_ms += 10) {
        const result = install(@intFromPtr(target), @intFromPtr(&hook), &trampoline);
        if (result != .not_ready) {
            expectResult(result, .ok, "after attaching it");
            break;
        }
        if (waited_ms > attach_timeout_ms) die("still not ready after attaching for {} ms", .{waited_ms});
        var message: win32.MSG = undefined;
        while (win32.PeekMessageW(&message, null, 0, 0, win32.PM_REMOVE) != 0) _ = win32.DispatchMessageW(&message);
        win32.Sleep(10);
    }

    // The hook runs in place of the target, and the trampoline runs the original.
    original = @ptrFromInt(trampoline);
    expectCall(target, 1005, "the hooked target");
    expectCall(original, 5, "the trampoline");

    // A second hook on the same target is refused, and the first still works.
    var second: usize = 0;
    expectResult(install(@intFromPtr(target), @intFromPtr(&hook), &second), .failed, "a second hook");
    expectCall(target, 1005, "after the refusal the target");

    // Any other thread is refused.
    var other_result: detour.DetourInstallResult = .ok;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(out: *detour.DetourInstallResult) void {
            var unused: usize = 0;
            out.* = install(0, 0, &unused);
        }
    }.run, .{&other_result});
    thread.join();
    expectResult(other_result, .wrong_thread, "another thread");

    // The attach thread and Mutiny's other threads are still around, so don't return through the CRT.
    std.process.exit(0);
}

const std = @import("std");
const detour = @import("detour.zig");
const dynlib = @import("dynlib.zig");
const win32 = @import("win32").everything;
