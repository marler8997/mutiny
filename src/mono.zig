pub const Domain = opaque {};
pub const Assembly = opaque {};
pub const Thread = opaque {};

const MonoFunc = fn (data: *anyopaque, user_data: *anyopaque) callconv(.c) void;

pub const Funcs = struct {
    get_root_domain: *const fn () callconv(.c) ?*Domain,
    thread_attach: *const fn (?*Domain) callconv(.c) ?*Thread,
    domain_assembly_open: *const fn (*Domain, [*:0]const u8) callconv(.c) ?*Assembly,
    assembly_foreach: *const fn (func: *const MonoFunc, user_data: *anyopaque) callconv(.c) void,
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!Funcs {
        return .{
            .get_root_domain = try getProc(proc_ref, mod, .get_root_domain),
            .thread_attach = try getProc(proc_ref, mod, .thread_attach),
            .domain_assembly_open = try getProc(proc_ref, mod, .domain_assembly_open),
            .assembly_foreach = try getProc(proc_ref, mod, .assembly_foreach),
        };
    }
};
fn getProc(
    proc_ref: *[:0]const u8,
    module: win32.HINSTANCE,
    comptime field: std.meta.FieldEnum(Funcs),
) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
    const func_name = "mono_" ++ @tagName(field);
    proc_ref.* = func_name;
    return getProc2(module, field);
}

fn getProc2(
    module: win32.HINSTANCE,
    comptime field: std.meta.FieldEnum(Funcs),
) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
    const func_name = "mono_" ++ @tagName(field);
    return @ptrCast(win32.GetProcAddress(module, func_name) orelse switch (win32.GetLastError()) {
        .ERROR_PROC_NOT_FOUND => return error.ProcNotFound,
        else => |e| std.debug.panic("GetProcAddress '{s}' with mono DLL failed, error={f}", .{ func_name, e }),
    });
}

const std = @import("std");
const win32 = @import("win32").everything;
