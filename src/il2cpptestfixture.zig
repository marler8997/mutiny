// il2cpp cannot load MutinyTest.dll, since that is IL and il2cpp has no IL execution. So the one
// class shared with the mono tests, MutinyTest.Test, is rebuilt here as a synthetic Il2CppClass
// whose methods are native functions. @TestClass() returns it (see Vm), so the same test scripts
// run on both runtimes. Keep the method list in step with managed/MutinyTest.cs's Test class.

const test_name = "Test";

const max_params = 3;

const Method = struct {
    name: [*:0]const u8,
    return_type: [:0]const u8,
    return_array: bool = false,
    param_types: []const [:0]const u8 = &.{},
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

fn echoObject(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    params: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    ret(?*anyopaque, out, params.?[0]);
}

fn addTicks(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    params: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    ret(i64, out, arg(i64, params, 0) + arg(i64, params, 1) + arg(i32, params, 2));
}

fn newArray(class: *const dotnet.Class, len: usize) struct { *const dotnet.Object, [*]u8 } {
    const f = installed.funcs;
    const array = f.il2cpp.array_new(class, len) orelse std.debug.panic(
        "il2cpp fixture: array_new of {} {s} returned null",
        .{ len, f.class_get_name(class) },
    );
    const data = @as([*]u8, @ptrCast(@constCast(array))) + f.il2cpp.array_object_header_size();
    return .{ array, data };
}

fn setRef(array: *const dotnet.Object, data: [*]u8, index: usize, value: ?*const dotnet.Object) void {
    const slot: *?*anyopaque = @ptrCast(@alignCast(data + index * @sizeOf(usize)));
    installed.funcs.il2cpp.gc_wbarrier_set_field(array, slot, @constCast(value));
}

fn newString(text: []const u8) *const dotnet.Object {
    return @ptrCast(installed.funcs.il2cpp.string_new_len(text.ptr, @intCast(text.len)) orelse std.debug.panic(
        "il2cpp fixture: string_new_len '{s}' returned null",
        .{text},
    ));
}

fn i32Array(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    _: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    const array, const data = newArray(installed.int32, 3);
    const values: [*]align(1) i32 = @ptrCast(data);
    values[0..3].* = .{ 10, 20, 30 };
    ret(*const dotnet.Object, out, array);
}

fn stringArray(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    _: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    const array, const data = newArray(installed.string, 2);
    setRef(array, data, 0, newString("a"));
    setRef(array, data, 1, newString("b"));
    ret(*const dotnet.Object, out, array);
}

fn objectArray(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    _: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    const array, const data = newArray(installed.object, 2);
    const ticks: i64 = 5;
    const boxed = installed.funcs.il2cpp.value_box(installed.time_span, &ticks) orelse @panic(
        "il2cpp fixture: value_box of a TimeSpan returned null",
    );
    setRef(array, data, 0, boxed);
    setRef(array, data, 1, null);
    ret(*const dotnet.Object, out, array);
}

fn timeSpanArray(
    _: il2cppclass.MethodPointer,
    _: *const dotnet.Method,
    _: ?*anyopaque,
    _: ?[*]?*anyopaque,
    out: ?*anyopaque,
) callconv(.c) void {
    const array, const data = newArray(installed.time_span, 2);
    const values: [*]align(1) i64 = @ptrCast(data);
    values[0..2].* = .{ 1, 2 };
    ret(*const dotnet.Object, out, array);
}

fn unusedMethodPointer() callconv(.c) void {
    unreachable;
}

const methods = [_]Method{
    // il2cpp passes a bool as one byte
    .{ .name = "EchoBool", .return_type = "Boolean", .param_types = &.{"Boolean"}, .invoker = echo(u8) },
    .{ .name = "EchoI8", .return_type = "SByte", .param_types = &.{"SByte"}, .invoker = echo(i8) },
    .{ .name = "EchoU8", .return_type = "Byte", .param_types = &.{"Byte"}, .invoker = echo(u8) },
    .{ .name = "EchoI16", .return_type = "Int16", .param_types = &.{"Int16"}, .invoker = echo(i16) },
    .{ .name = "EchoU16", .return_type = "UInt16", .param_types = &.{"UInt16"}, .invoker = echo(u16) },
    .{ .name = "EchoI32", .return_type = "Int32", .param_types = &.{"Int32"}, .invoker = echo(i32) },
    .{ .name = "EchoU32", .return_type = "UInt32", .param_types = &.{"UInt32"}, .invoker = echo(u32) },
    .{ .name = "EchoI64", .return_type = "Int64", .param_types = &.{"Int64"}, .invoker = echo(i64) },
    .{ .name = "EchoU64", .return_type = "UInt64", .param_types = &.{"UInt64"}, .invoker = echo(u64) },
    .{ .name = "EchoF32", .return_type = "Single", .param_types = &.{"Single"}, .invoker = echo(f32) },
    .{ .name = "EchoF64", .return_type = "Double", .param_types = &.{"Double"}, .invoker = echo(f64) },

    .{ .name = "U64Max", .return_type = "UInt64", .invoker = constant(u64, std.math.maxInt(u64)) },
    .{ .name = "I64Max", .return_type = "Int64", .invoker = constant(i64, std.math.maxInt(i64)) },
    .{ .name = "I64Min", .return_type = "Int64", .invoker = constant(i64, std.math.minInt(i64)) },
    .{ .name = "F32Huge", .return_type = "Single", .invoker = constant(f32, 3.4e38) },
    .{ .name = "F64Huge", .return_type = "Double", .invoker = constant(f64, 1e300) },

    .{ .name = "NullString", .return_type = "String", .invoker = &returnsNull },
    .{ .name = "NullObject", .return_type = "Object", .invoker = &returnsNull },

    .{ .name = "Overload", .return_type = "Int32", .param_types = &.{"Int32"}, .invoker = constant(i32, 1) },
    .{ .name = "Overload", .return_type = "Int32", .param_types = &.{"String"}, .invoker = constant(i32, 2) },
    .{ .name = "Overload", .return_type = "Int32", .param_types = &.{"Double"}, .invoker = constant(i32, 3) },
    .{ .name = "OverloadIntUint", .return_type = "Int32", .param_types = &.{"Int32"}, .invoker = constant(i32, 1) },
    .{ .name = "OverloadIntUint", .return_type = "Int32", .param_types = &.{"UInt32"}, .invoker = constant(i32, 2) },
    .{ .name = "OverloadInt32And64", .return_type = "Int32", .param_types = &.{"Int32"}, .invoker = constant(i32, 1) },
    .{ .name = "OverloadInt32And64", .return_type = "Int32", .param_types = &.{"Int64"}, .invoker = constant(i32, 2) },
    .{ .name = "EchoEnum", .return_type = "Int32", .param_types = &.{"DayOfWeek"}, .invoker = echo(i32) },
    .{ .name = "OverloadIntEnum", .return_type = "Int32", .param_types = &.{"Int32"}, .invoker = constant(i32, 1) },
    .{ .name = "OverloadIntEnum", .return_type = "Int32", .param_types = &.{"DayOfWeek"}, .invoker = constant(i32, 2) },

    // a TimeSpan is one long, and a struct parameter arrives as a pointer to it
    .{ .name = "TicksOf", .return_type = "Int64", .param_types = &.{"TimeSpan"}, .invoker = echo(i64) },
    .{ .name = "AddTicks", .return_type = "Int64", .param_types = &.{ "TimeSpan", "TimeSpan", "Int32" }, .invoker = &addTicks },
    .{ .name = "EchoObject", .return_type = "Object", .param_types = &.{"Object"}, .invoker = &echoObject },
    .{ .name = "TypeOrString", .return_type = "Int32", .param_types = &.{"Type"}, .invoker = constant(i32, 1) },
    .{ .name = "TypeOrString", .return_type = "Int32", .param_types = &.{"String"}, .invoker = constant(i32, 2) },
    .{ .name = "OverloadBoxed", .return_type = "Int32", .param_types = &.{"Object"}, .invoker = constant(i32, 1) },
    .{ .name = "OverloadBoxed", .return_type = "Int32", .param_types = &.{"TimeSpan"}, .invoker = constant(i32, 2) },

    .{ .name = "I32Array", .return_type = "Int32", .return_array = true, .invoker = &i32Array },
    .{ .name = "StringArray", .return_type = "String", .return_array = true, .invoker = &stringArray },
    .{ .name = "ObjectArray", .return_type = "Object", .return_array = true, .invoker = &objectArray },
    .{ .name = "TimeSpanArray", .return_type = "TimeSpan", .return_array = true, .invoker = &timeSpanArray },
    .{ .name = "NullI32Array", .return_type = "Int32", .return_array = true, .invoker = &returnsNull },
};

fn findClass(
    funcs: *const Funcs,
    assemblies: []const *const dotnet.Assembly,
    namespace: [*:0]const u8,
    name: [*:0]const u8,
) ?*const dotnet.Class {
    for (assemblies) |assembly| {
        const image = funcs.il2cpp.assembly_get_image(assembly);
        if (funcs.class_from_name(image, namespace, name)) |class| return class;
    }
    return null;
}

fn findSystemClass(
    funcs: *const Funcs,
    assemblies: []const *const dotnet.Assembly,
    name: [:0]const u8,
    method_name: [*:0]const u8,
) error{MissingClass}!*const dotnet.Class {
    return findClass(funcs, assemblies, "System", name.ptr) orelse {
        std.log.err("il2cpp fixture: no System.{s} for '{s}'", .{ name, method_name });
        return error.MissingClass;
    };
}

// The runtime keeps pointers into these, so they must outlive install and can't be const. install
// runs once, which is what makes one shared copy safe.
var method_storage: [methods.len]il2cppclass.SyntheticMethod = undefined;
var param_storage: [methods.len][max_params]*const dotnet.Type = undefined;
var method_ptrs: [methods.len]*const dotnet.Method = undefined;
var synthetic: ?il2cppclass.SyntheticClass = null;

// what the array invokers build their arrays from
var installed: struct {
    funcs: *const Funcs,
    int32: *const dotnet.Class,
    string: *const dotnet.Class,
    object: *const dotnet.Class,
    time_span: *const dotnet.Class,
} = undefined;

pub fn install(
    funcs: *const Funcs,
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
    funcs.il2cpp.runtime_class_init(object);
    const fixed_size = try il2cppclass.classFixedSize(unity_version);

    installed = .{
        .funcs = funcs,
        .int32 = try findSystemClass(funcs, assemblies, "Int32", "I32Array"),
        .string = try findSystemClass(funcs, assemblies, "String", "StringArray"),
        .object = object,
        .time_span = try findSystemClass(funcs, assemblies, "TimeSpan", "TimeSpanArray"),
    };

    for (&methods, 0..) |m, i| {
        const element_class = try findSystemClass(funcs, assemblies, m.return_type, m.name);
        const return_class = if (m.return_array) funcs.il2cpp.array_class_get(element_class, 1) orelse {
            std.log.err("il2cpp fixture: no System.{s}[] for '{s}'", .{ m.return_type, m.name });
            return error.MissingClass;
        } else element_class;
        const return_type = funcs.class_get_type(return_class);
        comptime std.debug.assert(for (methods) |checked| {
            if (checked.param_types.len > max_params) break false;
        } else true);
        for (m.param_types, 0..) |param_type, param_index| {
            const param_class = try findSystemClass(funcs, assemblies, param_type, m.name);
            param_storage[i][param_index] = funcs.class_get_type(param_class);
        }
        method_ptrs[i] = method_storage[i].init(layouts.method, .{
            .name = m.name,
            .return_type = return_type,
            .method_pointer = &unusedMethodPointer,
            .invoker = m.invoker,
            .parameters_count = @intCast(m.param_types.len),
            // PUBLIC | STATIC
            .flags = 0x0006 | 0x0010,
            // klass is patched in once the class exists
            .parameters = if (m.param_types.len == 0) null else &param_storage[i],
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

pub const Funcs = struct {
    class_from_name: *const dotnet.shared.class_from_name,
    class_get_type: *const dotnet.shared.class_get_type,
    class_get_name: *const dotnet.shared.class_get_name,
    il2cpp: struct {
        assembly_get_image: *const dotnet.il2cpp.assembly_get_image,
        runtime_class_init: *const dotnet.il2cpp.runtime_class_init,
        array_class_get: *const dotnet.il2cpp.array_class_get,
        array_new: *const dotnet.il2cpp.array_new,
        array_object_header_size: *const dotnet.il2cpp.array_object_header_size,
        gc_wbarrier_set_field: *const dotnet.il2cpp.gc_wbarrier_set_field,
        string_new_len: *const dotnet.il2cpp.string_new_len,
        value_box: *const dotnet.il2cpp.value_box,
    },
};

const std = @import("std");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const UnityVersion = @import("UnityVersion.zig");
