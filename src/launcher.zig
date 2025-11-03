const std = @import("std");
const win32 = @import("win32").everything;

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    std.log.info("=== Mod Framework Launcher ===", .{});
    const game_exe = try findGameExecutable(gpa);
    defer gpa.free(game_exe);

    std.log.info("Game: {s}", .{game_exe});

    // Find framework DLL
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_path_buf);

    var framework_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const framework_dll = try std.fmt.bufPrint(&framework_path_buf, "{s}{c}framework.dll", .{ exe_dir, std.fs.path.sep });

    // Check if framework DLL exists
    std.fs.accessAbsolute(framework_dll, .{}) catch {
        std.log.err("framework.dll not found at: {s}", .{framework_dll});
        std.process.exit(0xff);
        // std.log.info("Press Enter to exit...", .{});
        // _ = try std.io.getStdIn().reader().readByte();
        // return;
    };

    std.log.info("Framework: {s}", .{framework_dll});

    // Launch and inject
    std.log.info("Launching game...", .{});
    try launchAndInject(gpa, game_exe, framework_dll);
    std.log.info("Success! Game launched with framework injected.", .{});
    std.log.info("Check logs/ folder for framework output.", .{});
}

fn findGameExecutable(gpa: std.mem.Allocator) ![]const u8 {
    // const stdin = std.io.getStdIn().reader();

    // // Try to read from config file
    // var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // const exe_dir = try std.fs.selfExeDirPath(&exe_path_buf);

    // var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}{c}config.ini", .{ exe_dir, std.fs.path.sep });

    // if (std.fs.openFileAbsolute(config_path, .{})) |file| {
    //     defer file.close();

    //     var buf_reader = std.io.bufferedReader(file.reader());
    //     var reader = buf_reader.reader();

    //     var line_buf: [1024]u8 = undefined;
    //     while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
    //         const trimmed = std.mem.trim(u8, line, " \r\n\t");
    //         if (std.mem.startsWith(u8, trimmed, "game_path=")) {
    //             const path = std.mem.trim(u8, trimmed[10..], " \r\n\t");
    //             if (path.len > 0) {
    //                 std.fs.accessAbsolute(path, .{}) catch continue;
    //                 return try gpa.dupe(u8, path);
    //             }
    //         }
    //     }
    // } else |_| {
    //     // Config file doesn't exist, that's ok
    // }

    // Try common locations
    const common_paths = [_][]const u8{
        "C:\\Program Files (x86)\\Steam\\steamapps\\common\\REPO\\REPO.exe",
    };

    for (common_paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return try gpa.dupe(u8, path);
    }

    std.log.err("could not find game executable (todo: maybe make a way to configure this?)", .{});
    // // Prompt user
    // std.log.info("Could not auto-detect game location.", .{});
    // std.log.info("Enter path to game executable: ", .{});

    // var path_buf: [1024]u8 = undefined;
    // const user_input = try stdin.readUntilDelimiterOrEof(&path_buf, '\n');
    // if (user_input) |path| {
    //     const trimmed = std.mem.trim(u8, path, " \r\n\t");
    //     std.fs.accessAbsolute(trimmed, .{}) catch {
    //         std.log.err("File not found: {s}", .{trimmed});
    //         return error.FileNotFound;
    //     };

    //     // Save to config for next time
    //     const file = try std.fs.createFileAbsolute(config_path, .{});
    //     defer file.close();
    //     try file.writer().print("game_path={s}\n", .{trimmed});

    //     return try gpa.dupe(u8, trimmed);
    // }

    return error.NoGameFound;
}

fn launchAndInject(
    gpa: std.mem.Allocator,
    game_exe: []const u8,
    dll_path: []const u8,
) !void {
    // Convert paths to UTF-16 (need allocator for this)
    const game_exe_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, game_exe);
    defer gpa.free(game_exe_w);

    const dll_path_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, dll_path);
    defer gpa.free(dll_path_w);

    // Get game directory without allocator
    const game_dir = std.fs.path.dirname(game_exe) orelse return error.InvalidPath;
    const game_dir_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, game_dir);
    defer gpa.free(game_dir_w);

    // Setup process creation structures
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
        game_exe_w.ptr,
        null,
        null,
        null,
        0,
        win32.CREATE_SUSPENDED,
        null,
        game_dir_w.ptr,
        &si,
        &pi,
    );
    if (result == 0) win32.panicWin32("CreateProcess", win32.GetLastError());

    std.log.info("Process created (PID: {})", .{pi.dwProcessId});
    injectDLL(pi.hProcess.?, dll_path_w) catch |err| {
        _ = win32.TerminateProcess(pi.hProcess, 1);
        return err;
    };

    std.log.info("DLL injected successfully", .{});

    // Resume the process
    _ = win32.ResumeThread(pi.hThread);
    std.log.info("Process resumed", .{});

    // Close handles
    _ = win32.CloseHandle(pi.hProcess);
    _ = win32.CloseHandle(pi.hThread);
}

fn injectDLL(
    process: win32.HANDLE,
    dll_path_w: [*:0]const u16,
) !void {
    // Calculate size needed for DLL path (in bytes, including null terminator)
    const path_len = std.mem.indexOfSentinel(u16, 0, dll_path_w);
    const path_size = (path_len + 1) * @sizeOf(u16);

    // Allocate memory in target process
    const remote_mem = win32.VirtualAllocEx(
        process,
        null,
        path_size,
        .{ .COMMIT = 1, .RESERVE = 1 },
        win32.PAGE_READWRITE,
    ) orelse {
        const err = win32.GetLastError();
        std.log.err("VirtualAllocEx failed. Error code: {}", .{@intFromEnum(err)});
        return error.AllocFailed;
    };

    const dll_path_bytes = @as([*]const u8, @ptrCast(dll_path_w))[0..path_size];
    const write_result = win32.WriteProcessMemory(
        process,
        remote_mem,
        dll_path_bytes.ptr,
        path_size,
        null,
    );

    if (write_result == 0) {
        const err = win32.GetLastError();
        std.log.err("WriteProcessMemory failed. Error code: {}", .{@intFromEnum(err)});
        return error.WriteFailed;
    }

    // Get address of LoadLibraryW
    const kernel32 = win32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse {
        std.log.err("GetModuleHandleW failed", .{});
        return error.GetModuleFailed;
    };

    const load_library_addr = win32.GetProcAddress(kernel32, "LoadLibraryW") orelse {
        std.log.err("GetProcAddress failed", .{});
        return error.GetProcAddressFailed;
    };

    // Create remote thread to call LoadLibraryW
    const thread = win32.CreateRemoteThread(
        process,
        null,
        0,
        @ptrCast(load_library_addr),
        remote_mem,
        0,
        null,
    ) orelse {
        const err = win32.GetLastError();
        std.log.err("CreateRemoteThread failed. Error code: {}", .{@intFromEnum(err)});
        return error.CreateThreadFailed;
    };

    // Wait for LoadLibrary to complete
    _ = win32.WaitForSingleObject(thread, win32.INFINITE);
    _ = win32.CloseHandle(thread);

    // Free allocated memory
    _ = win32.VirtualFreeEx(process, remote_mem, 0, win32.MEM_RELEASE);
}
