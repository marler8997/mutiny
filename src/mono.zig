pub const Domain = opaque {};
pub const Assembly = opaque {};
pub const Thread = opaque {};

pub const Funcs = struct {
    get_root_domain: *const fn () callconv(.c) ?*Domain,
    thread_attach: *const fn (?*Domain) callconv(.c) ?*Thread,
    domain_assembly_open: *const fn (*Domain, [*:0]const u8) callconv(.c) ?*Assembly,
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!Funcs {
        return .{
            .get_root_domain = try maybeGetProc(proc_ref, mod, fn () callconv(.c) ?*Domain, "mono_get_root_domain"),
            .thread_attach = try maybeGetProc(proc_ref, mod, fn (?*Domain) callconv(.c) ?*Thread, "mono_thread_attach"),
            .domain_assembly_open = try maybeGetProc(proc_ref, mod, fn (*Domain, [*:0]const u8) callconv(.c) ?*Assembly, "mono_domain_assembly_open"),
        };
    }
    fn maybeGetProc(proc_ref: *[:0]const u8, module: win32.HINSTANCE, comptime T: type, name: [:0]const u8) error{ProcNotFound}!*const T {
        proc_ref.* = name;
        return getProc(module, T, name);
    }
};

fn getProc(module: win32.HINSTANCE, comptime T: type, name: [:0]const u8) error{ProcNotFound}!*const T {
    return @ptrCast(win32.GetProcAddress(module, name) orelse switch (win32.GetLastError()) {
        .ERROR_PROC_NOT_FOUND => return error.ProcNotFound,
        else => |e| std.debug.panic("GetProcAddress '{s}' with mono DLL failed, error={f}", .{ name, e }),
    });
}

const std = @import("std");
const win32 = @import("win32").everything;
