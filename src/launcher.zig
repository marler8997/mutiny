const std = @import("std");
const win32 = @import("win32").everything;

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    if (all_args.len <= 1) {
        try std.fs.File.stderr().writeAll("Usage: launcher.exe MUTINY_DLL [pid PID][exe EXE...]\n");
        std.process.exit(0xff);
    }
    const args = all_args[1..];
    if (args.len < 2) {
        std.log.err("expected at least 2 cmdline args but got {}", .{args.len});
        std.process.exit(0xff);
    }
    const mutiny_dll_arg = args[0];
    const kind_string = args[1];
    const kind: union(enum) { pid: u32, exe: struct {
        path: [:0]const u8,
        args: []const [:0]const u8,
    } } = blk: {
        if (std.mem.eql(u8, kind_string, "pid")) {
            if (args.len < 3) errExit("missing the pid number after 'pid' on the cmdline", .{});
            const pid_string = args[2];
            const pid = std.fmt.parseInt(u32, pid_string, 10) catch errExit("invalid pid '{s}'", .{pid_string});
            if (args.len > 3) errExit("too many cmdline args (nothing expected after pid number)", .{});
            break :blk .{ .pid = pid };
        }
        if (std.mem.eql(u8, kind_string, "exe")) break :blk .{ .exe = .{
            .path = args[2],
            .args = args[3..],
        } };
        errExit("expected 'pid' or 'exe' cmdline arg but got '{s}'", .{kind_string});
    };
    // TODO: should we enforce that the DLL path is absolute so that it guarantees it isn't
    //       overriden by something else?
    std.fs.cwd().access(mutiny_dll_arg, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("mutiny dll '{s}' not found", .{mutiny_dll_arg});
            std.process.exit(0xff);
        },
        else => |e| return e,
    };
    // convert the mutiny DLL path to a real absolute path so that it can be loaded by the
    // game process.
    const mutiny_dll_realpath = std.fs.cwd().realpathAlloc(gpa, mutiny_dll_arg) catch |err| errExit(
        "convert mutiny dll path '{s}' to realpath failed with {s}",
        .{ mutiny_dll_arg, @errorName(err) },
    );
    defer gpa.free(mutiny_dll_realpath);

    const mutiny_dll_realpath_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, mutiny_dll_realpath);
    defer gpa.free(mutiny_dll_realpath_w);

    const process: ProcessResult = blk: switch (kind) {
        .pid => |pid| {
            const process = win32.OpenProcess(
                .{
                    .VM_OPERATION = 1, // Required for VirtualAllocEx/VirtualFreeEx
                    .VM_WRITE = 1, // Required for WriteProcessMemory
                    .CREATE_THREAD = 1, // Required for CreateRemoteThread
                },
                0, // do not inherit handle,
                pid,
            ) orelse errExit("OpenProcess pid {} failed, error={f}", .{ pid, win32.GetLastError() });
            break :blk .{ .created = false, .pid = pid, .process = process, .maybe_suspended_thread = null };
        },
        .exe => |exe| {
            if (exe.args.len > 0) @panic("TODO: support extra exe cmdline args");
            std.fs.accessAbsolute(exe.path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err("'{s}' not found", .{exe.path});
                    std.process.exit(0xff);
                },
                else => |e| return e,
            };
            std.log.info("launching '{s}'...", .{exe.path});
            const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, exe.path);
            defer gpa.free(exe_w);
            break :blk try createProcess(exe_w);
        },
    };
    defer process.deinit();
    errdefer {
        if (process.created) {
            std.log.info("terminating process {}", .{process.pid});
            if (0 == win32.TerminateProcess(process.process, 1)) {
                std.log.err("TerminateProcess {} failed, error={}", .{ process.pid, win32.GetLastError() });
            }
        }
    }

    const inject_dll = true;
    if (inject_dll) injectDLL(process.process, mutiny_dll_realpath_w) catch |err| {
        return err;
    };

    if (process.maybe_suspended_thread) |thread| {
        std.log.info("resuming new process thread...", .{});
        const suspend_count = win32.ResumeThread(thread);
        if (suspend_count == -1) std.debug.panic(
            "ResumeThread failed, error={}",
            .{win32.GetLastError()},
        );
        std.log.info("process thread resumed (suspend_count={})", .{suspend_count});
    }

    std.log.info("success", .{});
}

fn getDirname(path: []const u16) ?[]const u16 {
    for (1..path.len) |i| {
        if (path[path.len - i] == '\\')
            return path[0 .. path.len - i];
    }
    return null;
}

const ProcessResult = struct {
    created: bool,
    pid: u32,
    process: win32.HANDLE,
    maybe_suspended_thread: ?win32.HANDLE,
    pub fn deinit(result: *const ProcessResult) void {
        if (result.maybe_suspended_thread) |t| {
            win32.closeHandle(t);
        }
        defer win32.closeHandle(result.process);
    }
};

fn createProcess(game_exe: [:0]const u16) !ProcessResult {
    const stdout_path = win32.L("C:\\temp\\mutiny-stdout.log");
    const stderr_path = win32.L("C:\\temp\\mutiny-stderr.log");

    var security_attrs: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };

    const stdout_file: std.fs.File = .{
        .handle = win32.CreateFileW(
            stdout_path,
            .{ .FILE_APPEND_DATA = 1 }, // all writes append to end of file
            .{ .READ = 1 },
            &security_attrs,
            .CREATE_ALWAYS, // always create and truncate the file
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        ),
    };
    if (stdout_file.handle == win32.INVALID_HANDLE_VALUE) win32.panicWin32(
        "CreateFileW (stdout)",
        win32.GetLastError(),
    );
    defer stdout_file.close();

    security_attrs = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };

    const stderr_file: std.fs.File = .{
        .handle = win32.CreateFileW(
            stderr_path,
            .{ .FILE_APPEND_DATA = 1 }, // all writes append to end of file
            .{ .READ = 1 },
            &security_attrs,
            .CREATE_ALWAYS, // always create and truncate the file
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        ),
    };
    if (stderr_file.handle == win32.INVALID_HANDLE_VALUE) win32.panicWin32(
        "CreateFileW (stdout)",
        win32.GetLastError(),
    );
    defer stderr_file.close();

    if (true) {
        var stdout = stdout_file.writer(&.{});
        stdout.interface.writeAll("launcher has created this log for the child process stdout\n") catch {
            std.log.err(
                "write to stdout failed with {t}",
                .{stdout.err orelse error.Unexpected},
            );
        };
    }
    if (true) {
        var stderr = stderr_file.writer(&.{});
        stderr.interface.writeAll("launcher has created this log for the child process stderr\n") catch {
            std.log.err(
                "write to stderr failed with {t}",
                .{stderr.err orelse error.Unexpected},
            );
        };
    }

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
        .dwFlags = .{ .USESTDHANDLES = 1 },
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = std.fs.File.stdin().handle,
        .hStdOutput = stdout_file.handle,
        .hStdError = stderr_file.handle,
    };

    var pi: win32.PROCESS_INFORMATION = undefined;

    const result = win32.CreateProcessW(
        game_exe.ptr,
        null,
        null,
        null,
        1, // bInheritHandles
        win32.CREATE_SUSPENDED,
        null,
        // game_dir_w.ptr,
        null,
        &si,
        &pi,
    );
    if (result == 0) win32.panicWin32("CreateProcess", win32.GetLastError());
    std.log.info("created game process (pid {})", .{pi.dwProcessId});
    return .{
        .created = true,
        .pid = pi.dwProcessId,
        .process = pi.hProcess.?,
        .maybe_suspended_thread = pi.hThread.?,
    };
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

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}
