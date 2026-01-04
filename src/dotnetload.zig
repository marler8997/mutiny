pub fn template(comptime Funcs: anytype) type {
    return struct {
        pub fn get(
            module: win32.HINSTANCE,
            comptime field: std.meta.FieldEnum(Funcs),
            proc_ref: *[:0]const u8,
        ) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
            const func_name = "mono_" ++ @tagName(field);
            proc_ref.* = func_name;
            return get2(module, field);
        }

        pub fn get2(
            module: win32.HINSTANCE,
            comptime field: std.meta.FieldEnum(Funcs),
        ) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
            const func_name = "mono_" ++ @tagName(field);
            return @ptrCast(win32.GetProcAddress(module, func_name) orelse switch (win32.GetLastError()) {
                .ERROR_PROC_NOT_FOUND => return error.ProcNotFound,
                else => |e| std.debug.panic("GetProcAddress '{s}' on dotnet DLL failed, error={f}", .{ func_name, e }),
            });
        }
    };
}

const std = @import("std");
const win32 = @import("win32").everything;
