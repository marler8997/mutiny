pub const Module = if (builtin.os.tag == .windows) win32.HINSTANCE else *anyopaque;

pub const LoadError = error{
    NotFound,
    Unexpected,
};

pub fn load(path: [:0]u8) LoadError!Module {
    if (builtin.os.tag == .windows) return loadWindows(path);
    return loadPosix(path);
}

pub const GetProcError = error{
    ProcNotFound,
    Unexpected,
};

pub fn getProc(module: Module, name: [:0]const u8) GetProcError!*const anyopaque {
    if (builtin.os.tag == .windows) return getProcWindows(module, name);
    return getProcPosix(module, name);
}

fn loadWindows(path: [:0]u8) LoadError!Module {
    if (win32.LoadLibraryA(path)) |h| {
        std.log.info("LoadLibrary: SetDllDirectory not required", .{});
        return h;
    }
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => {},
        else => |e| {
            std.log.err(
                "LoadLibrary '{s}' (before SetDllDirectory) failed with unexpected error: {f}",
                .{ path, e },
            );
            return error.Unexpected;
        },
    }
    // The DLL or one of its dependencies wasn't found. A game's runtime DLL
    // sits next to its dependencies, so retry with that dir on the search path.
    const dir = std.fs.path.dirname(path) orelse return error.NotFound;
    const set_dll_result = blk: {
        const save = path[dir.len];
        path[dir.len] = 0;
        defer path[dir.len] = save;
        break :blk win32.SetDllDirectoryA(path);
    };
    if (set_dll_result == 0) {
        std.log.err(
            "SetDllDirectory '{s}' failed with unexpected error: {f}",
            .{ path[0..dir.len], win32.GetLastError() },
        );
        return error.Unexpected;
    }
    if (win32.LoadLibraryA(path)) |h| {
        std.log.info("LoadLibrary: after SetDllDirectory", .{});
        return h;
    }
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => return error.NotFound,
        else => |e| {
            std.log.err(
                "LoadLibrary '{s}' (after SetDllDirectory) failed with unexpected error: {f}",
                .{ path, e },
            );
            return error.Unexpected;
        },
    }
}

fn getProcWindows(module: Module, name: [:0]const u8) GetProcError!*const anyopaque {
    if (win32.GetProcAddress(module, name)) |proc| return @ptrCast(proc);
    switch (win32.GetLastError()) {
        .ERROR_PROC_NOT_FOUND => return error.ProcNotFound,
        else => |e| {
            std.log.err("GetProcAddress '{s}' failed with unexpected error: {f}", .{ name, e });
            return error.Unexpected;
        },
    }
}

fn loadPosix(path: [:0]u8) LoadError!Module {
    _ = path;
    @panic("todo");
}

fn getProcPosix(module: Module, name: [:0]const u8) GetProcError!*const anyopaque {
    _ = module;
    _ = name;
    @panic("todo");
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
