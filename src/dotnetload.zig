pub fn template(comptime Funcs: anytype) type {
    return struct {
        pub fn get(
            module: dynlib.Module,
            comptime field: std.meta.FieldEnum(Funcs),
            func_name: [:0]const u8,
            proc_ref: *[:0]const u8,
        ) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
            proc_ref.* = func_name;
            const proc = dynlib.getProc(module, func_name) catch |err| switch (err) {
                error.ProcNotFound => return error.ProcNotFound,
                error.Unexpected => std.debug.panic(
                    "GetProc '{s}' on dotnet DLL failed with {s}",
                    .{ func_name, @errorName(err) },
                ),
            };
            return @ptrCast(@alignCast(proc));
        }

        pub fn sharedGet(
            kind: Kind,
            module: dynlib.Module,
            comptime field: std.meta.FieldEnum(Funcs),
            proc_ref: *[:0]const u8,
        ) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
            return get(module, field, switch (kind) {
                .mono => "mono_" ++ @tagName(field),
                .il2cpp => "il2cpp_" ++ @tagName(field),
            }, proc_ref);
        }

        pub fn monoGet(
            module: dynlib.Module,
            comptime field: std.meta.FieldEnum(Funcs),
            proc_ref: *[:0]const u8,
        ) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
            return get(module, field, "mono_" ++ @tagName(field), proc_ref);
        }

        pub fn il2cppGet(
            module: dynlib.Module,
            comptime field: std.meta.FieldEnum(Funcs),
            proc_ref: *[:0]const u8,
        ) error{ProcNotFound}!@FieldType(Funcs, @tagName(field)) {
            return get(module, field, "il2cpp_" ++ @tagName(field), proc_ref);
        }
    };
}

const std = @import("std");
const dynlib = @import("dynlib.zig");
const dotnetkind = @import("dotnetkind.zig");
const Kind = dotnetkind.Kind;
