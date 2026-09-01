pub fn startExe(
    arena: std.mem.Allocator,
    dll: []const u8,
    exe: []const u8,
) !void {
    const exe_wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, exe);
    defer arena.free(exe_wide);
    const name = getname.fromExe(exe_wide) catch |err| errExit("invalid exe '{f}' ({s})", .{
        std.unicode.fmtUtf16Le(exe_wide), switch (err) {
            error.Empty => "can't just be an empty string",
            error.EndsInSeparator => "cannot end with a filesystem separator",
            error.JustDotExe => "can't just be '.exe'",
        },
    });
    try go(arena, dll, .{ .start = .{
        .exe = exe_wide,
        .name = name,
    } });
}
pub fn attach(arena: std.mem.Allocator, dll: []const u8, pid: u32) !void {
    try go(arena, dll, .{ .attach = pid });
}

const Kind = union(enum) {
    attach: u32,
    start: struct {
        exe: [:0]const u16,
        // args: []const [:0]const u8,
        name: []const u16,
    },
};

fn go(arena: std.mem.Allocator, mutiny_dll_arg: []const u8, kind: Kind) !void {
    switch (kind) {
        .attach => |pid| switch (mutinyipc.checkLiveness(pid)) {
            .serving => errExit("pid {} already has mutiny running in it", .{pid}),
            .unresponsive => errExit(
                "pid {} has a mutiny window that isn't responding, it may be in the middle of a managed call, restart the app",
                .{pid},
            ),
            .no_window => {},
        },
        .start => {},
    }

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
    // game process regardless of it's CWD.
    const mutiny_dll_realpath = std.fs.cwd().realpathAlloc(arena, mutiny_dll_arg) catch |err| errExit(
        "convert mutiny dll path '{s}' to realpath failed with {s}",
        .{ mutiny_dll_arg, @errorName(err) },
    );
    // no need to free
    const mutiny_dll_realpath_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, mutiny_dll_realpath);
    // no need to free

    const process: ProcessResult = blk: switch (kind) {
        .attach => |pid| {
            const process = win32.OpenProcess(
                .{
                    .VM_OPERATION = 1, // Required for VirtualAllocEx/VirtualFreeEx
                    .VM_WRITE = 1, // Required for WriteProcessMemory
                    .CREATE_THREAD = 1, // Required for CreateRemoteThread
                    .SYNCHRONIZE = 1, // Required for WaitForSingleObject
                    .QUERY_LIMITED_INFORMATION = 1, // Required for GetExitCodeProcess
                },
                0, // do not inherit handle,
                pid,
            ) orelse errExit("OpenProcess pid {} failed, error={f}", .{ pid, win32.GetLastError() });
            break :blk .{ .created = false, .pid = pid, .process = process, .maybe_suspended_thread = null };
        },
        .start => |start| break :blk try createProcess(start.name, start.exe),
    };
    defer process.deinit();
    errdefer {
        if (process.created) {
            std.log.info("terminating process {}", .{process.pid});
            if (0 == win32.TerminateProcess(process.process, 1)) {
                std.log.err("TerminateProcess {} failed, error={f}", .{ process.pid, win32.GetLastError() });
            }
        }
    }

    const maybe_loaded: ?*u8 = switch (kind) {
        .attach => findRemoteModule(process.pid),
        .start => null,
    };
    const remote_base = blk: {
        if (maybe_loaded) |base| {
            std.log.info("Mutiny.dll already loaded in pid {}", .{process.pid});
            break :blk base;
        }
        try injectDLL(process.process, mutiny_dll_realpath_w);
        break :blk findRemoteModule(process.pid) orelse errExit(
            "Mutiny.dll is not loaded in pid {} even after injecting it",
            .{process.pid},
        );
    };
    try startThread(process, remote_base, mutiny_dll_realpath_w);

    if (process.maybe_suspended_thread) |thread| {
        std.log.info("resuming new process thread...", .{});
        const suspend_count = win32.ResumeThread(thread);
        if (suspend_count == -1) std.debug.panic(
            "ResumeThread failed, error={}",
            .{win32.GetLastError()},
        );
        std.log.info("process thread resumed (suspend_count={})", .{suspend_count});
    }

    try waitForWindow(process);
    std.log.info("success", .{});
}

fn startThread(process: ProcessResult, remote_base: *u8, dll_path: [:0]const u16) !void {
    const start_rva = blk: {
        const local = win32.LoadLibraryW(dll_path) orelse win32.panicWin32(
            "LoadLibrary(ourself)",
            win32.GetLastError(),
        );
        const local_start = win32.GetProcAddress(
            local,
            mutinyipc.start_export_name,
        ) orelse win32.panicWin32(
            "GetProcAddress(" ++ mutinyipc.start_export_name ++ ")",
            win32.GetLastError(),
        );
        break :blk @intFromPtr(local_start) - @intFromPtr(local);
    };
    const remote_start = @intFromPtr(remote_base) + start_rva;
    std.log.info("calling {s} at 0x{x} in pid {}", .{
        mutinyipc.start_export_name,
        remote_start,
        process.pid,
    });
    const thread = win32.CreateRemoteThread(
        process.process,
        null,
        mutinyipc.thread_stack_size,
        @ptrFromInt(remote_start),
        null,
        0,
        null,
    ) orelse win32.panicWin32("CreateRemoteThread", win32.GetLastError());
    win32.closeHandle(thread);
}

fn findRemoteModule(pid: u32) ?*u8 {
    const modules = blk: while (true) {
        const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPMODULE, pid);
        if (snapshot != win32.INVALID_HANDLE_VALUE) break :blk snapshot;
        switch (win32.GetLastError()) {
            .ERROR_BAD_LENGTH => {},
            else => |e| win32.panicWin32("CreateToolhelp32Snapshot", e),
        }
    };
    defer win32.closeHandle(modules);

    var module: win32.MODULEENTRY32W = undefined;
    module.dwSize = @sizeOf(win32.MODULEENTRY32W);
    if (0 == win32.Module32FirstW(modules, &module)) switch (win32.GetLastError()) {
        .ERROR_NO_MORE_FILES => return null,
        else => |e| win32.panicWin32("Module32First", e),
    };
    while (true) {
        const name = std.mem.sliceTo(@as([*:0]const u16, @ptrCast(&module.szModule)), 0);
        if (eqlAsciiIgnoreCase(name, mutiny_dll_name)) return module.modBaseAddr;
        if (0 == win32.Module32NextW(modules, &module)) switch (win32.GetLastError()) {
            .ERROR_NO_MORE_FILES => return null,
            else => |e| win32.panicWin32("Module32Next", e),
        };
    }
}

const mutiny_dll_name = "Mutiny.dll";

fn eqlAsciiIgnoreCase(wide: []const u16, ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |w, a| {
        if (w > 127) return false;
        if (std.ascii.toLower(@intCast(w)) != std.ascii.toLower(a)) return false;
    }
    return true;
}

const wait_for_window_ms = 10000;

fn waitForWindow(process: ProcessResult) !void {
    var attempt: u32 = 0;
    const start = try std.time.Instant.now();
    while (true) : (attempt += 1) {
        switch (mutinyipc.checkLiveness(process.pid)) {
            .serving => {
                std.log.info("mutiny is serving pid {}", .{process.pid});
                return;
            },
            .no_window, .unresponsive => {},
        }

        const elapsed_ms = @divTrunc((try std.time.Instant.now()).since(start), std.time.ns_per_ms);
        if (elapsed_ms >= wait_for_window_ms) errExit(
            "no mutiny window in pid {} after {} ms ({} attempts)",
            .{ process.pid, elapsed_ms, attempt },
        );
        switch (win32.WaitForSingleObject(process.process, 50)) {
            @intFromEnum(win32.WAIT_OBJECT_0) => {
                var exit_code: u32 = undefined;
                if (0 == win32.GetExitCodeProcess(process.process, &exit_code)) win32.panicWin32(
                    "GetExitCodeProcess",
                    win32.GetLastError(),
                );
                errExit(
                    "process {} exited with {} before mutiny started serving it",
                    .{ process.pid, exit_code },
                );
            },
            @intFromEnum(win32.WAIT_TIMEOUT) => {},
            else => |result| errExit(
                "wait on process {} returned {}, error={f}",
                .{ process.pid, result, win32.GetLastError() },
            ),
        }
    }
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

fn createProcess(name: []const u16, game_exe: [:0]const u16) !ProcessResult {
    const localappdata = appdata.get() orelse errExit(
        "no LOCALAPPDATA environment variable",
        .{},
    );

    // these sit beside this game's log and mods, so the injector and the injected
    // DLL agree on one directory per game
    var stdout_path_buf: [appdata.max_path]u16 = undefined;
    const stdout_path = switch (appdata.format(
        &stdout_path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("stdout.txt") },
    )) {
        .ok => |p| p,
        .too_long => errExit("path for game '{f}' is too long", .{std.unicode.fmtUtf16Le(name)}),
    };
    var stderr_path_buf: [appdata.max_path]u16 = undefined;
    const stderr_path = switch (appdata.format(
        &stderr_path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("stderr.txt") },
    )) {
        .ok => |p| p,
        .too_long => errExit("path for game '{f}' is too long", .{std.unicode.fmtUtf16Le(name)}),
    };

    // makeDirs puts back every character it terminates over, so stdout_path survives
    const game_dir_len = appdata.parentDirLen(stdout_path);
    std.debug.assert(game_dir_len > 0);
    if (appdata.makeDirs(&stdout_path_buf, game_dir_len)) |err| win32.panicWin32("CreateDirectory", err);

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
        stdout.interface.writeAll("injector has created this log for the child process stdout\n") catch {
            std.log.err(
                "write to stdout failed with {t}",
                .{stdout.err orelse error.Unexpected},
            );
        };
    }
    if (true) {
        var stderr = stderr_file.writer(&.{});
        stderr.interface.writeAll("injector has created this log for the child process stderr\n") catch {
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
    if (result == 0) switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND => errExit("executable '{f}' does not exist", .{std.unicode.fmtUtf16Le(game_exe)}),
        else => |e| win32.panicWin32("CreateProcess", e),
    };
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
        "{f}: loaded at address 0x{x} (might be truncated)",
        .{ std.unicode.fmtUtf16Le(dll_path), exit_code },
    );
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const win32 = @import("win32").everything;
const getname = @import("getname.zig");
const appdata = @import("appdata.zig");
const mutinyipc = @import("mutinyipc.zig");
