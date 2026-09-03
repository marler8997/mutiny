// il2cpp cannot load MutinyTest.dll, since that is IL and il2cpp has no IL execution. So the one
// class shared with the mono tests, MutinyTest.Test, is rebuilt here as a synthetic Il2CppClass
// whose methods are native functions. @TestClass() returns it (see Vm), so the same test scripts
// run on both runtimes. Keep the method list in step with managed/MutinyTest.cs's Test class.

const test_name = "Test";

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
    .{ .name = "EchoBool", .params = 1, .return_type = "Boolean", .invoker = echo(u8) },
    .{ .name = "EchoI8", .params = 1, .return_type = "SByte", .invoker = echo(i8) },
    .{ .name = "EchoU8", .params = 1, .return_type = "Byte", .invoker = echo(u8) },
    .{ .name = "EchoI16", .params = 1, .return_type = "Int16", .invoker = echo(i16) },
    .{ .name = "EchoU16", .params = 1, .return_type = "UInt16", .invoker = echo(u16) },
    .{ .name = "EchoI32", .params = 1, .return_type = "Int32", .invoker = echo(i32) },
    .{ .name = "EchoU32", .params = 1, .return_type = "UInt32", .invoker = echo(u32) },
    .{ .name = "EchoI64", .params = 1, .return_type = "Int64", .invoker = echo(i64) },
    .{ .name = "EchoU64", .params = 1, .return_type = "UInt64", .invoker = echo(u64) },
    .{ .name = "EchoF32", .params = 1, .return_type = "Single", .invoker = echo(f32) },
    .{ .name = "EchoF64", .params = 1, .return_type = "Double", .invoker = echo(f64) },

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

// The runtime keeps pointers into these, so they must outlive install and can't be const. install
// runs once, which is what makes one shared copy safe.
var method_storage: [methods.len]il2cppclass.SyntheticMethod = undefined;
var param_storage: [methods.len]*const dotnet.Type = undefined;
var method_ptrs: [methods.len]*const dotnet.Method = undefined;
var synthetic: ?il2cppclass.SyntheticClass = null;

pub fn install(
    funcs: *const dotnet.Funcs,
    // performs a single allocation, ok to use std.heap.page_allocator
    allocator: std.mem.Allocator,
    layouts: il2cppclass.Layouts,
    unity_version: UnityVersion,
    assemblies: []const *const dotnet.Assembly,
) error{ MissingClass, UnsupportedUnityVersion, OutOfMemory, TooManyMethods, BaseNotReadable }!void {
    if (synthetic != null) return;

    const object = findClass(funcs, assemblies, "System", "Object") orelse {
        std.log.err("il2cpp fixture: no System.Object to base the test class on", .{});
        return error.MissingClass;
    };
    // Object may only be lazily set up; force its Class::Init so the copy inherits a valid class
    funcs.kind.il2cpp.runtime_class_init(object);
    const fixed_size = try il2cppclass.classFixedSize(unity_version);

    for (&methods, 0..) |m, i| {
        const return_class = findClass(funcs, assemblies, "System", m.return_type.ptr) orelse {
            std.log.err("il2cpp fixture: no System.{s} for '{s}'", .{ m.return_type, m.name });
            return error.MissingClass;
        };
        const return_type = funcs.class_get_type(return_class);
        // every echo method's parameter type is its return type; one slot each, so a method's
        // parameter list is param_storage[i..i+1]
        std.debug.assert(m.params <= 1);
        param_storage[i] = return_type;
        method_ptrs[i] = method_storage[i].init(layouts.method, .{
            .name = m.name,
            .return_type = return_type,
            .method_pointer = &unusedMethodPointer,
            .invoker = m.invoker,
            .parameters_count = m.params,
            // PUBLIC | STATIC
            .flags = 0x0006 | 0x0010,
            // klass is patched in once the class exists
            .parameters = if (m.params == 0) null else param_storage[i .. i + 1].ptr,
        });
    }

    synthetic = try il2cppclass.SyntheticClass.build(allocator, layouts.class, fixed_size, object, &method_ptrs);
    const klass = synthetic.?.class();
    for (&method_storage) |*m| m.setKlass(layouts.method, klass);

    std.log.info("il2cpp fixture: built synthetic {s} with {} methods", .{ test_name, methods.len });
}

// The synthetic MutinyTest.Test class @TestClass() returns on il2cpp. install must have run first.
pub fn testClass() *const dotnet.Class {
    return (synthetic orelse @panic("il2cpp test fixture not installed")).class();
}

const std = @import("std");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const UnityVersion = @import("UnityVersion.zig");
