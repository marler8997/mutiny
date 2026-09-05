pub fn go(arena: std.mem.Allocator) !u8 {
    _ = arena;
    const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0);
    if (snapshot == win32.INVALID_HANDLE_VALUE) errExit(
        "unable to enumerate processes, error={f}",
        .{win32.GetLastError()},
    );
    defer win32.closeHandle(snapshot);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout.interface;

    var entry: win32.PROCESSENTRY32W = undefined;
    // the API rejects the call unless we say how big our struct is
    entry.dwSize = @sizeOf(win32.PROCESSENTRY32W);
    if (0 == win32.Process32FirstW(snapshot, &entry)) switch (win32.GetLastError()) {
        .ERROR_NO_MORE_FILES => return 0,
        else => |e| errExit("unable to enumerate processes, error={f}", .{e}),
    };

    var found: u32 = 0;
    while (true) {
        if (inspect(entry.th32ProcessID)) |target| {
            found += 1;
            const exe = std.mem.sliceTo(@as([*:0]const u16, @ptrCast(&entry.szExeFile)), 0);
            const name = getname.fromExe(exe) catch exe;
            const status: Status = if (!target.injected) .clean else switch (mutinyipc.checkLiveness(entry.th32ProcessID)) {
                .no_window => .injected,
                .serving => .attached,
                .unresponsive => .unresponsive,
            };
            try out.print("{d: <7} \"{f}\" {s} ({s})\n", .{
                entry.th32ProcessID,
                std.unicode.fmtUtf16Le(name),
                @tagName(status),
                @tagName(target.runtime),
            });
        }
        if (0 == win32.Process32NextW(snapshot, &entry)) switch (win32.GetLastError()) {
            .ERROR_NO_MORE_FILES => break,
            else => |e| errExit("unable to enumerate processes, error={f}", .{e}),
        };
    }

    if (found == 0) try out.writeAll("nothing running with a mono or il2cpp runtime loaded\n");
    try out.flush();
    return 0;
}

const Status = enum {
    clean,
    injected,
    attached,
    unresponsive,
};

const Target = struct {
    runtime: dotnetkind.Kind,
    injected: bool,
};

/// What a process has loaded, or null if it has no .NET runtime and so is nothing
/// Mutiny can do anything with. Those are the same two DLLs the injected DLL polls for
/// in `getDotNet`, which is what makes this the right filter: "it's Unity" would both
/// miss non-Unity mono apps and include games too early in startup to inject into.
fn inspect(pid: u32) ?Target {
    // pid 0 is the idle process and has no modules worth asking about
    if (pid == 0) return null;

    // Most failures here are system processes we have no rights to, which we'd never
    // be injecting into anyway.
    const modules = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPMODULE, pid);
    if (modules == win32.INVALID_HANDLE_VALUE) return null;
    defer win32.closeHandle(modules);

    var runtime: ?dotnetkind.Kind = null;
    var injected = false;

    var module: win32.MODULEENTRY32W = undefined;
    module.dwSize = @sizeOf(win32.MODULEENTRY32W);
    if (0 == win32.Module32FirstW(modules, &module)) return null;
    // no early exit: our own DLL can appear anywhere in the list, before or after the
    // runtime, so both answers need the whole walk
    while (true) {
        const name = std.mem.sliceTo(@as([*:0]const u16, @ptrCast(&module.szModule)), 0);
        if (eqlAscii(name, dotnetkind.dll_name_mono)) {
            runtime = .mono;
        } else if (eqlAscii(name, dotnetkind.dll_name_il2cpp)) {
            runtime = .il2cpp;
        } else if (eqlAscii(name, mutiny_dll)) {
            injected = true;
        }
        if (0 == win32.Module32NextW(modules, &module)) break;
    }
    return .{ .runtime = runtime orelse return null, .injected = injected };
}

const mutiny_dll = "Mutiny.dll";

/// Module names are ASCII and Windows compares them case-insensitively.
fn eqlAscii(wide: []const u16, ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |w, a| {
        if (w > 127) return false;
        if (std.ascii.toLower(@intCast(w)) != std.ascii.toLower(a)) return false;
    }
    return true;
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");

const dotnetkind = mutiny.dotnetkind;
const getname = mutiny.getname;
const mutinyipc = mutiny.mutinyipc;
