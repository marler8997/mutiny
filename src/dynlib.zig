pub const Module = if (builtin.os.tag == .windows) win32.HINSTANCE else *anyopaque;

pub const LoadError = error{
    NotFound,
    Unexpected,
};

pub fn load(path: [:0]const u8) LoadError!Module {
    if (builtin.os.tag == .windows) return loadWindows(path);
    return loadPosix(path);
}

pub fn setDllDirectoryOf(path: [:0]u8) LoadError!void {
    if (builtin.os.tag != .windows) @panic("todo");
    const dir = std.fs.path.dirname(path) orelse return error.NotFound;
    const save = path[dir.len];
    path[dir.len] = 0;
    defer path[dir.len] = save;
    if (0 == win32.SetDllDirectoryA(path[0..dir.len :0])) {
        std.log.err(
            "SetDllDirectory '{s}' failed with unexpected error: {f}",
            .{ path[0..dir.len], win32.GetLastError() },
        );
        return error.Unexpected;
    }
}

pub const GetProcError = error{
    ProcNotFound,
    Unexpected,
};

pub fn getProc(module: Module, name: [:0]const u8) GetProcError!*const anyopaque {
    if (builtin.os.tag == .windows) return getProcWindows(module, name);
    return getProcPosix(module, name);
}

fn loadWindows(path: [:0]const u8) LoadError!Module {
    if (win32.LoadLibraryA(path)) |h| return h;
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => return error.NotFound,
        else => |e| {
            std.log.err("LoadLibrary '{s}' failed with unexpected error: {f}", .{ path, e });
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

fn loadPosix(path: [:0]const u8) LoadError!Module {
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
