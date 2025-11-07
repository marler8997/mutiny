const std = @import("std");
const win32 = @import("win32").everything;

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    if (all_args.len <= 1) {
        try std.fs.File.stderr().writeAll("Usage: launcher.exe MARLER_MOD_NATIVE_DLL MARLER_MOD_MANAGED_DLL EXE\n");
        std.process.exit(0xff);
    }
    const args = all_args[1..];
    if (args.len != 3) {
        std.log.err("expected 3 cmdline args but got {}", .{args.len});
        std.process.exit(0xff);
    }
    const marler_mod_native_dll = args[0];
    const marler_mod_managed_dll = args[1];
    const exe = args[2];

    // std.fs.accessAbsolute(marler_mod_native_dll, .{}) catch {
    //     std.log.err("{s} not found", .{marler_mod_native_dll});
    //     std.process.exit(0xff);
    // };
    // std.fs.accessAbsolute(marler_mod_managed_dll, .{}) catch {
    //     std.log.err("{s} not found", .{marler_mod_managed_dll});
    //     std.process.exit(0xff);
    // };
    _ = marler_mod_managed_dll;

    std.log.info("launching '{s}'...", .{exe});

    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, exe);
    defer gpa.free(exe_w);

    try launchAndInject(gpa, exe_w, marler_mod_native_dll);
    std.log.info("Success! Game launched with framework injected.", .{});
    std.log.info("Check logs/ folder for framework output.", .{});
}

fn getDirname(path: []const u16) ?[]const u16 {
    for (1..path.len) |i| {
        if (path[path.len - i] == '\\')
            return path[0 .. path.len - i];
    }
    return null;
}

fn launchAndInject(
    gpa: std.mem.Allocator,
    game_exe: [:0]const u16,
    dll_path: []const u8,
) !void {
    const dll_path_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, dll_path);
    defer gpa.free(dll_path_w);

    // const game_dir: []const u16 = getDirname(game_exe) orelse win32.L(".");

    var si: win32.STARTUPINFOW = .{
        .cb = @sizeOf(win32.STARTUPINFOW),
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .dwFlags = .{},
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = null,
        .hStdOutput = null,
        .hStdError = null,
    };

    var pi: win32.PROCESS_INFORMATION = undefined;

    // Create process in suspended state
    const result = win32.CreateProcessW(
        game_exe.ptr,
        null,
        null,
        null,
        0,
        win32.CREATE_SUSPENDED,
        null,
        // game_dir_w.ptr,
        null,
        &si,
        &pi,
    );
    if (result == 0) win32.panicWin32("CreateProcess", win32.GetLastError());

    std.log.info("created game process (pid {})", .{pi.dwProcessId});
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    const inject_dll = true;
    if (inject_dll) injectDLL(pi.hProcess.?, dll_path_w) catch |err| {
        _ = win32.TerminateProcess(pi.hProcess, 1);
        return err;
    };

    // Resume the process
    _ = win32.ResumeThread(pi.hThread);
    std.log.info("Process resumed", .{});

    // Close handles
    _ = win32.CloseHandle(pi.hProcess);
    _ = win32.CloseHandle(pi.hThread);
}

fn injectDLL(process: win32.HANDLE, dll_path: [:0]const u16) !void {
    const path_size = (dll_path.len + 1) * @sizeOf(u16);
    const remote_mem = win32.VirtualAllocEx(
        process,
        null,
        path_size,
        .{ .COMMIT = 1, .RESERVE = 1 },
        win32.PAGE_READWRITE,
    ) orelse std.debug.panic(
        "VirtualAllocEx ({} bytes) for game process failed, error={f}",
        .{ path_size, win32.GetLastError() },
    );
    defer if (0 == win32.VirtualFreeEx(
        process,
        remote_mem,
        0,
        win32.MEM_RELEASE,
    )) win32.panicWin32("VirtualFreeEx", win32.GetLastError());

    const dll_path_bytes = @as([*]const u8, @ptrCast(dll_path))[0..path_size];
    if (0 == win32.WriteProcessMemory(
        process,
        remote_mem,
        dll_path_bytes.ptr,
        path_size,
        null,
    )) std.debug.panic(
        "WriteProcessMemory for dll path ({} bytes) failed, error={f}",
        .{ path_size, win32.GetLastError() },
    );
    const kernel32 = win32.GetModuleHandleW(win32.L("kernel32.dll")) orelse win32.panicWin32(
        "GetModuleHandle(kernel32)",
        win32.GetLastError(),
    );
    const load_library_addr = win32.GetProcAddress(kernel32, "LoadLibraryW") orelse win32.panicWin32(
        "GetProcAddress(LoadLibrary)",
        win32.GetLastError(),
    );
    const thread = win32.CreateRemoteThread(
        process,
        null,
        0,
        @ptrCast(load_library_addr),
        remote_mem,
        0,
        null,
    ) orelse win32.panicWin32(
        "CreateRemoteThread",
        win32.GetLastError(),
    );
    defer win32.closeHandle(thread);
    switch (win32.WaitForSingleObject(thread, win32.INFINITE)) {
        @intFromEnum(win32.WAIT_OBJECT_0) => {},
        @intFromEnum(win32.WAIT_FAILED) => win32.panicWin32("WaitForSingleObject(thread)", win32.GetLastError()),
        else => |result| {
            std.debug.panic("WaitForSingleObject(thread) returned {}", .{result});
        },
    }

    var exit_code: u32 = undefined;
    if (0 == win32.GetExitCodeThread(thread, &exit_code)) win32.panicWin32(
        "GetExitCodeThread",
        win32.GetLastError(),
    );

    if (exit_code == 0) {
        std.log.err(
            "{f}: _DllMainCRTStartup for process attach failed.",
            .{std.unicode.fmtUtf16Le(dll_path)},
        );
        std.process.exit(0xff);
    }
    std.log.debug(
        "{f}: Loaded at address 0x{x} (might be truncated)",
        .{ std.unicode.fmtUtf16Le(dll_path), exit_code },
    );
}
