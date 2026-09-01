// il2cpp cannot load MutinyTest.dll, since that is IL and il2cpp has no IL execution. So the
// static-method half of that fixture is injected here instead: the same method names, backed
// by native functions, appended to a type that is guaranteed to exist. Tests then run the same
// assertions on both runtimes, differing only in which class they look the methods up on.
//
// Instance types (MutinyTest.Instances) are not here: they need a new type, which needs a
// metadata handle we cannot fabricate.

const host_namespace = "System";
const host_name = "Int32";

const Method = struct {
    name: [*:0]const u8,
    params: u8,
    return_type: [:0]const u8,
    invoker: il2cppclass.InvokerMethod,
};

fn arg(comptime T: type, params: ?[*]?*anyopaque, index: usize) T {
    const p: *align(1) const T = @ptrCast(params.?[index].?);
    return p.*;
}

fn ret(comptime T: type, out: ?*anyopaque, value: T) void {
    const p: *align(1) T = @ptrCast(out.?);
    p.* = value;
}

fn echo(comptime T: type) il2cppclass.InvokerMethod {
    return &struct {
        fn invoke(
            _: il2cppclass.MethodPointer,
            _: *const dotnet.Method,
            _: ?*anyopaque,
            params: ?[*]?*anyopaque,
            out: ?*anyopaque,
        ) callconv(.c) void {
            ret(T, out, arg(T, params, 0));
        }
    }.invoke;
}

fn constant(comptime T: type, comptime value: T) il2cppclass.InvokerMethod {
    return &struct {
        fn invoke(
            _: il2cppclass.MethodPointer,
            _: *const dotnet.Method,
            _: ?*anyopaque,
            _: ?[*]?*anyopaque,
            out: ?*anyopaque,
        ) callconv(.c) void {
            ret(T, out, value);
        }
    }.invoke;
}

fn returnsNull(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    _: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    ret(?*anyopaque, out, null);
}

fn unusedMethodPointer() callconv(.c) void {
    unreachable;
}

const methods = [_]Method{
    // il2cpp passes a bool as one byte
    .{ .name = "Bool", .params = 1, .return_type = "Boolean", .invoker = echo(u8) },
    .{ .name = "I8", .params = 1, .return_type = "SByte", .invoker = echo(i8) },
    .{ .name = "U8", .params = 1, .return_type = "Byte", .invoker = echo(u8) },
    .{ .name = "I16", .params = 1, .return_type = "Int16", .invoker = echo(i16) },
    .{ .name = "U16", .params = 1, .return_type = "UInt16", .invoker = echo(u16) },
    .{ .name = "I32", .params = 1, .return_type = "Int32", .invoker = echo(i32) },
    .{ .name = "U32", .params = 1, .return_type = "UInt32", .invoker = echo(u32) },
    .{ .name = "I64", .params = 1, .return_type = "Int64", .invoker = echo(i64) },
    .{ .name = "U64", .params = 1, .return_type = "UInt64", .invoker = echo(u64) },
    .{ .name = "F32", .params = 1, .return_type = "Single", .invoker = echo(f32) },
    .{ .name = "F64", .params = 1, .return_type = "Double", .invoker = echo(f64) },

    .{ .name = "U64Max", .params = 0, .return_type = "UInt64", .invoker = constant(u64, std.math.maxInt(u64)) },
    .{ .name = "I64Max", .params = 0, .return_type = "Int64", .invoker = constant(i64, std.math.maxInt(i64)) },
    .{ .name = "I64Min", .params = 0, .return_type = "Int64", .invoker = constant(i64, std.math.minInt(i64)) },
    .{ .name = "F32Huge", .params = 0, .return_type = "Single", .invoker = constant(f32, 3.4e38) },
    .{ .name = "F64Huge", .params = 0, .return_type = "Double", .invoker = constant(f64, 1e300) },

    .{ .name = "NullString", .params = 0, .return_type = "String", .invoker = &returnsNull },
    .{ .name = "NullObject", .params = 0, .return_type = "Object", .invoker = &returnsNull },
};

fn findClass(
    funcs: *const dotnet.Funcs,
    assemblies: []const *const dotnet.Assembly,
    namespace: [*:0]const u8,
    name: [*:0]const u8,
) ?*const dotnet.Class {
    for (assemblies) |assembly| {
        const image = funcs.kind.il2cpp.assembly_get_image(assembly);
        if (funcs.class_from_name(image, namespace, name)) |class| return class;
    }
    return null;
}

// The runtime keeps pointers into these, so they must outlive install, and their contents are
// runtime values so they cannot be const. install refuses to run twice, which is what makes
// one shared copy safe.
var method_storage: [methods.len]il2cppclass.SyntheticMethod = undefined;
var param_storage: [methods.len]*const dotnet.Type = undefined;

pub fn install(
    funcs: *const dotnet.Funcs,
    // performs a single allocation, ok to use std.heap.page_allocator
    allocator: std.mem.Allocator,
    layout: il2cppclass.Layout,
    method_layout: il2cppclass.MethodLayout,
    assemblies: []const *const dotnet.Assembly,
) error{ MissingClass, OutOfMemory, TooManyMethods }!void {
    const host = findClass(funcs, assemblies, host_namespace, host_name) orelse {
        std.log.err("il2cpp fixture: no {s}.{s} to host the methods", .{ host_namespace, host_name });
        return error.MissingClass;
    };

    if (funcs.class_get_method_from_name(host, methods[0].name, methods[0].params) != null) {
        std.log.info("il2cpp fixture: already installed on {s}.{s}", .{ host_namespace, host_name });
        return;
    }

    var new_methods: [methods.len]*const dotnet.Method = undefined;
    for (&methods, 0..) |m, i| {
        const return_class = findClass(funcs, assemblies, "System", m.return_type.ptr) orelse {
            std.log.err("il2cpp fixture: no System.{s} for '{s}'", .{ m.return_type, m.name });
            return error.MissingClass;
        };
        const return_type = funcs.class_get_type(return_class);
        // every method here echoes its argument, so the parameter type is the return type.
        // One slot each, so a method's parameter list is param_storage[i..i+1]: more than one
        // parameter would read the next method's type.
        std.debug.assert(m.params <= 1);
        param_storage[i] = return_type;

        new_methods[i] = method_storage[i].init(method_layout, .{
            .name = m.name,
            .return_type = return_type,
            .method_pointer = &unusedMethodPointer,
            .invoker = m.invoker,
            .parameters_count = m.params,
            // PUBLIC | STATIC
            .flags = 0x0006 | 0x0010,
            .klass = host,
            .parameters = if (m.params == 0) null else param_storage[i .. i + 1].ptr,
        });
    }
    try il2cppclass.appendMethods(layout, allocator, host, &new_methods);

    std.log.info("il2cpp fixture: added {} methods to {s}.{s}", .{
        methods.len,
        host_namespace,
        host_name,
    });
}

const std = @import("std");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
