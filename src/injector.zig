pub const InjectError = union(enum) {
    os: Error,
    denied: [:0]const u8,
    already_attached,
    unresponsive,
    invalid_exe: []const u8,
    exe_not_found,
    dll_not_found: []const u8,
    dll_load_failed,
    dll_not_loaded,
    no_localappdata,
    game_path_too_long,
    attach_failed,
    attach_thread_exit: u32,
    game_exited: u32,

    pub fn format(e: InjectError, w: *std.Io.Writer) error{WriteFailed}!void {
        switch (e) {
            .os => |os| try os.format(w),
            .denied => |what| try w.print(
                "{s} was denied; anti-cheat such as Easy Anti-Cheat does this, so launch the game without it to attach",
                .{what},
            ),
            .already_attached => try w.writeAll("Mutiny is already running in the game"),
            .unresponsive => try w.writeAll("Mutiny's window in the game is not responding; it may be in the middle of a managed call, so restart the game"),
            .invalid_exe => |reason| try w.print("the exe path {s}", .{reason}),
            .exe_not_found => try w.writeAll("the exe does not exist"),
            .dll_not_found => |path| try w.print("there is no " ++ dll_name ++ " at '{s}'", .{path}),
            .dll_load_failed => try w.writeAll("loading " ++ dll_name ++ " inside the game failed"),
            .dll_not_loaded => try w.writeAll(dll_name ++ " is not loaded in the game even after injecting it"),
            .no_localappdata => try w.writeAll("there is no LOCALAPPDATA environment variable"),
            .game_path_too_long => try w.writeAll("the path of the game's mutiny directory is too long"),
            .attach_failed => try w.writeAll("Mutiny could not attach inside the game, see the game's mutiny log"),
            .attach_thread_exit => |code| try w.print("the attach thread in the game exited with 0x{x}, see the game's mutiny log", .{code}),
            .game_exited => |code| try w.print("the game exited with code {} before Mutiny attached", .{code}),
        }
    }

    fn set(out_err: *InjectError, e: InjectError) error{Error} {
        out_err.* = e;
        return error.Error;
    }

    fn setAny(out_err: *InjectError, what: [:0]const u8, any: anyerror) error{Error} {
        return out_err.set(.{ .os = .initAny(what, any) });
    }

    fn setWin32(out_err: *InjectError, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
        return out_err.set(.{ .os = .initWin32(what, code) });
    }

    fn setRemote(out_err: *InjectError, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
        return switch (code) {
            .ERROR_ACCESS_DENIED => out_err.set(.{ .denied = what }),
            else => out_err.setWin32(what, code),
        };
    }
};

pub fn startExe(
    arena: std.mem.Allocator,
    dll: []const u8,
    exe: []const u8,
    out_err: *InjectError,
) error{Error}!void {
    const exe_wide = std.unicode.utf8ToUtf16LeAllocZ(arena, exe) catch |e| return out_err.setAny("converting the exe path", e);
    defer arena.free(exe_wide);
    const name = getname.fromExe(exe_wide) catch |err| return out_err.set(.{ .invalid_exe = switch (err) {
        error.Empty => "is empty",
        error.EndsInSeparator => "ends in a path separator",
        error.JustDotExe => "is just '.exe'",
    } });
    try go(arena, dll, .{ .start = .{
        .exe = exe_wide,
        .name = name,
    } }, out_err);
}
pub fn attach(arena: std.mem.Allocator, dll: []const u8, pid: u32, out_err: *InjectError) error{Error}!void {
    try go(arena, dll, .{ .attach = pid }, out_err);
}

const Kind = union(enum) {
    attach: u32,
    start: struct {
        exe: [:0]const u16,
        // args: []const [:0]const u8,
        name: []const u16,
    },
};

fn go(arena: std.mem.Allocator, mutiny_dll_arg: []const u8, kind: Kind, out_err: *InjectError) error{Error}!void {
    switch (kind) {
        .attach => |pid| switch (mutinyipc.checkLiveness(pid)) {
            .serving => return out_err.set(.already_attached),
            .unresponsive => return out_err.set(.unresponsive),
            .no_window => {},
        },
        .start => {},
    }

    // TODO: should we enforce that the DLL path is absolute so that it guarantees it isn't
    //       overriden by something else?
    std.fs.cwd().access(mutiny_dll_arg, .{}) catch |err| switch (err) {
        error.FileNotFound => return out_err.set(.{ .dll_not_found = mutiny_dll_arg }),
        else => |e| return out_err.setAny("checking for " ++ dll_name, e),
    };
    // convert the mutiny DLL path to a real absolute path so that it can be loaded by the
    // game process regardless of it's CWD.
    const mutiny_dll_realpath = std.fs.cwd().realpathAlloc(arena, mutiny_dll_arg) catch |e| return out_err.setAny(
        "resolving the " ++ dll_name ++ " path",
        e,
    );
    // no need to free
    const mutiny_dll_realpath_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, mutiny_dll_realpath) catch |e| return out_err.setAny(
        "converting the " ++ dll_name ++ " path",
        e,
    );
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
            ) orelse return out_err.setWin32("OpenProcess", win32.GetLastError());
            break :blk .{ .created = false, .pid = pid, .process = process, .maybe_suspended_thread = null };
        },
        .start => |start| break :blk try createProcess(arena, start.name, start.exe, out_err),
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
        .attach => try findRemoteModule(process.pid, out_err),
        .start => null,
    };
    const remote_base = blk: {
        if (maybe_loaded) |base| {
            std.log.info("Mutiny.dll already loaded in pid {}", .{process.pid});
            break :blk base;
        }
        try injectDLL(process.process, mutiny_dll_realpath_w, out_err);
        break :blk (try findRemoteModule(process.pid, out_err)) orelse return out_err.set(.dll_not_loaded);
    };
    const attach_thread = try startAttachThread(process, remote_base, mutiny_dll_realpath_w, out_err);
    defer win32.closeHandle(attach_thread);

    if (process.maybe_suspended_thread) |thread| {
        std.log.info("resuming new process thread...", .{});
        const suspend_count = win32.ResumeThread(thread);
        if (suspend_count == -1) return out_err.setWin32("ResumeThread", win32.GetLastError());
        std.log.info("process thread resumed (suspend_count={})", .{suspend_count});
    }

    try waitForAttach(process, attach_thread, out_err);
    std.log.info("success", .{});
}

fn startAttachThread(
    process: ProcessResult,
    remote_base: *u8,
    dll_path: [:0]const u16,
    out_err: *InjectError,
) error{Error}!win32.HANDLE {
    const start_rva = blk: {
        const local = win32.LoadLibraryW(dll_path) orelse return out_err.setWin32(
            "loading " ++ dll_name ++ " into this process",
            win32.GetLastError(),
        );
        const local_start = win32.GetProcAddress(
            local,
            mutinyipc.attach_export_name,
        ) orelse return out_err.setWin32(
            "finding " ++ mutinyipc.attach_export_name ++ " in " ++ dll_name,
            win32.GetLastError(),
        );
        break :blk @intFromPtr(local_start) - @intFromPtr(local);
    };
    const remote_start = @intFromPtr(remote_base) + start_rva;
    std.log.info("calling {s} at 0x{x} in pid {}", .{
        mutinyipc.attach_export_name,
        remote_start,
        process.pid,
    });
    const thread = win32.CreateRemoteThread(
        process.process,
        null,
        mutinyipc.thread_stack_size,
        @ptrFromInt(remote_start),
        @ptrFromInt(attach_timeout_ms),
        0,
        null,
    ) orelse return out_err.setRemote("starting the attach thread in the game", win32.GetLastError());
    return thread;
}

const attach_timeout_ms = 10 * 1000;

fn waitForAttach(process: ProcessResult, attach_thread: win32.HANDLE, out_err: *InjectError) error{Error}!void {
    const handles = [_]?win32.HANDLE{ attach_thread, process.process };
    switch (win32.WaitForMultipleObjects(handles.len, &handles, 0, win32.INFINITE)) {
        @intFromEnum(win32.WAIT_OBJECT_0) => {
            var exit_code: u32 = undefined;
            if (0 == win32.GetExitCodeThread(attach_thread, &exit_code)) win32.panicWin32(
                "GetExitCodeThread",
                win32.GetLastError(),
            );
            switch (exit_code) {
                mutinyipc.AttachResult.success => std.log.info("mutiny is attached to pid {}", .{process.pid}),
                mutinyipc.AttachResult.fail => return out_err.set(.attach_failed),
                else => return out_err.set(.{ .attach_thread_exit = exit_code }),
            }
        },
        @intFromEnum(win32.WAIT_OBJECT_0) + 1 => {
            var exit_code: u32 = undefined;
            if (0 == win32.GetExitCodeProcess(process.process, &exit_code)) win32.panicWin32(
                "GetExitCodeProcess",
                win32.GetLastError(),
            );
            return out_err.set(.{ .game_exited = exit_code });
        },
        @intFromEnum(win32.WAIT_FAILED) => return out_err.setWin32("WaitForMultipleObjects", win32.GetLastError()),
        else => |result| std.debug.panic("WaitForMultipleObjects(INFINITE) returned {}", .{result}),
    }
}

fn findRemoteModule(pid: u32, out_err: *InjectError) error{Error}!?*u8 {
    const modules = blk: while (true) {
        const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPMODULE, pid);
        if (snapshot != win32.INVALID_HANDLE_VALUE) break :blk snapshot;
        switch (win32.GetLastError()) {
            .ERROR_BAD_LENGTH => {},
            else => |e| return out_err.setRemote("listing the game's modules", e),
        }
    };
    defer win32.closeHandle(modules);

    var module: win32.MODULEENTRY32W = undefined;
    module.dwSize = @sizeOf(win32.MODULEENTRY32W);
    if (0 == win32.Module32FirstW(modules, &module)) switch (win32.GetLastError()) {
        .ERROR_NO_MORE_FILES => return null,
        else => |e| return out_err.setWin32("Module32First", e),
    };
    while (true) {
        const name = std.mem.sliceTo(@as([*:0]const u16, @ptrCast(&module.szModule)), 0);
        if (eqlAsciiIgnoreCase(name, dll_name)) return module.modBaseAddr;
        if (0 == win32.Module32NextW(modules, &module)) switch (win32.GetLastError()) {
            .ERROR_NO_MORE_FILES => return null,
            else => |e| return out_err.setWin32("Module32Next", e),
        };
    }
}

fn eqlAsciiIgnoreCase(wide: []const u16, ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |w, a| {
        if (w > 127) return false;
        if (std.ascii.toLower(@intCast(w)) != std.ascii.toLower(a)) return false;
    }
    return true;
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

fn createProcess(
    arena: std.mem.Allocator,
    name: []const u16,
    game_exe: [:0]const u16,
    out_err: *InjectError,
) error{Error}!ProcessResult {
    const env_block: ?[*]u16 = blk: {
        const app_id = (steam.findAppId(arena, game_exe) catch |err| {
            std.log.warn(
                "could not read the steam app id for '{f}' ({t}), the game may relaunch itself through Steam",
                .{ std.unicode.fmtUtf16Le(game_exe), err },
            );
            break :blk null;
        }) orelse break :blk null;
        var id_buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
        const id = id_buf[0..std.fmt.printInt(&id_buf, app_id, 10, .lower, .{})];
        var env = std.process.getEnvMap(arena) catch |e| return out_err.setAny("reading the environment", e);
        env.put("SteamAppId", id) catch |e| return out_err.setAny("setting SteamAppId", e);
        env.put("SteamGameId", id) catch |e| return out_err.setAny("setting SteamGameId", e);
        std.log.info("steam app id {d}: SteamAppId is set so the game does not relaunch itself through Steam", .{app_id});
        const block = std.process.createWindowsEnvBlock(arena, &env) catch |e| return out_err.setAny("building the environment", e);
        break :blk block.ptr;
    };

    const localappdata = appdata.get() orelse return out_err.set(.no_localappdata);

    // these sit beside this game's log and mods, so the injector and the injected
    // DLL agree on one directory per game
    var stdout_path_buf: [appdata.max_path]u16 = undefined;
    const stdout_path = switch (appdata.format(
        &stdout_path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("stdout.txt") },
    )) {
        .ok => |p| p,
        .too_long => return out_err.set(.game_path_too_long),
    };
    var stderr_path_buf: [appdata.max_path]u16 = undefined;
    const stderr_path = switch (appdata.format(
        &stderr_path_buf,
        localappdata,
        &.{ win32.L("mutiny"), win32.L("app"), name, win32.L("stderr.txt") },
    )) {
        .ok => |p| p,
        .too_long => return out_err.set(.game_path_too_long),
    };

    // makeDirs puts back every character it terminates over, so stdout_path survives
    const game_dir_len = appdata.parentDirLen(stdout_path);
    std.debug.assert(game_dir_len > 0);
    if (appdata.makeDirs(&stdout_path_buf, game_dir_len)) |err| return out_err.setWin32("creating the game's mutiny directory", err);

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
    if (stdout_file.handle == win32.INVALID_HANDLE_VALUE) return out_err.setWin32("creating stdout.txt", win32.GetLastError());
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
    if (stderr_file.handle == win32.INVALID_HANDLE_VALUE) return out_err.setWin32("creating stderr.txt", win32.GetLastError());
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
        .{ .CREATE_SUSPENDED = 1, .CREATE_UNICODE_ENVIRONMENT = 1 },
        env_block,
        // game_dir_w.ptr,
        null,
        &si,
        &pi,
    );
    if (result == 0) switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => return out_err.set(.exe_not_found),
        else => |e| return out_err.setWin32("CreateProcess", e),
    };
    std.log.info("created game process (pid {})", .{pi.dwProcessId});
    return .{
        .created = true,
        .pid = pi.dwProcessId,
        .process = pi.hProcess.?,
        .maybe_suspended_thread = pi.hThread.?,
    };
}

fn injectDLL(process: win32.HANDLE, dll_path: [:0]const u16, out_err: *InjectError) error{Error}!void {
    const path_size = (dll_path.len + 1) * @sizeOf(u16);
    const remote_mem = win32.VirtualAllocEx(
        process,
        null,
        path_size,
        .{ .COMMIT = 1, .RESERVE = 1 },
        win32.PAGE_READWRITE,
    ) orelse return out_err.setRemote("allocating memory in the game", win32.GetLastError());
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
    )) return out_err.setRemote("writing the game's memory", win32.GetLastError());
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
    ) orelse return out_err.setRemote("starting a thread in the game", win32.GetLastError());
    defer win32.closeHandle(thread);
    switch (win32.WaitForSingleObject(thread, win32.INFINITE)) {
        @intFromEnum(win32.WAIT_OBJECT_0) => {},
        @intFromEnum(win32.WAIT_FAILED) => return out_err.setWin32("waiting for LoadLibrary in the game", win32.GetLastError()),
        else => |result| {
            std.debug.panic("WaitForSingleObject(thread) returned {}", .{result});
        },
    }

    var exit_code: u32 = undefined;
    if (0 == win32.GetExitCodeThread(thread, &exit_code)) win32.panicWin32(
        "GetExitCodeThread",
        win32.GetLastError(),
    );

    if (exit_code == 0) return out_err.set(.dll_load_failed);
    std.log.debug(
        "{f}: loaded at address 0x{x} (might be truncated)",
        .{ std.unicode.fmtUtf16Le(dll_path), exit_code },
    );
}

/// Where Mutiny.dll lives relative to the running exe: the CLI in bin\ passes "..\dll", the
/// GUI at the appdata root passes "dll".
pub fn findDll(arena: std.mem.Allocator, relative_dir: []const u8, out_err: *InjectError) error{Error}![]const u8 {
    const exe_dir = std.fs.selfExeDirPathAlloc(arena) catch |e| return out_err.setAny(
        "locating this exe's directory to find " ++ dll_name,
        e,
    );
    defer arena.free(exe_dir);
    const path = std.fs.path.resolve(arena, &.{ exe_dir, relative_dir, dll_name }) catch |e| return out_err.setAny(
        "building the " ++ dll_name ++ " path",
        e,
    );
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return out_err.set(.{ .dll_not_found = path }),
        else => |e| return out_err.setAny("checking for " ++ dll_name, e),
    };
    std.log.info("found dll at '{s}'", .{path});
    return path;
}

const dll_name = "Mutiny.dll";

const std = @import("std");
const win32 = @import("win32").everything;

const appdata = @import("appdata.zig");
const getname = @import("getname.zig");
const mutinyipc = @import("mutinyipc.zig");
const steam = @import("steam.zig");

const Error = @import("Error.zig");
