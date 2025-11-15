threadlocal var thread_local_root_domain: ?*Domain = null;

pub fn setRootDomain(domain: *Domain) void {
    std.debug.assert(domain.attached_thread == null);
    std.debug.assert(thread_local_root_domain == null);
    thread_local_root_domain = domain;
}
pub fn unsetRootDomain(domain: *Domain) void {
    std.debug.assert(domain.attached_thread == null);
    std.debug.assert(thread_local_root_domain == domain);
    thread_local_root_domain = null;
}

pub const funcs: mono.Funcs = .{
    .get_root_domain = mock_get_root_domain,
    .domain_get = mock_domain_get,
    .thread_attach = mock_thread_attach,
    .thread_detach = mock_thread_detach,
    .assembly_foreach = mock_assembly_foreach,
    .assembly_get_name = mock_assembly_get_name,
    .assembly_get_image = mock_assembly_get_image,
    .assembly_name_get_name = mock_assembly_name_get_name,
    .class_from_name = mock_class_from_name,
    .class_get_method_from_name = mock_class_get_method_from_name,
    .class_get_field_from_name = mock_class_get_field_from_name,
    .field_get_flags = mock_field_get_flags,
    .field_get_type = mock_field_get_type,
    .field_get_value = mock_field_get_value,
    .method_get_flags = mock_method_get_flags,
    .method_signature = mock_method_signature,
    .method_get_class = mock_method_get_class,
    .signature_get_return_type = mock_signature_get_return_type,
    .signature_get_params = mock_signature_get_params,
    .type_get_type = mock_type_get_type,
    .object_new = mock_object_new,
    .object_unbox = mock_object_unbox,
    .gchandle_new = mock_gchandle_new,
    .gchandle_free = mock_gchandle_free,
    .gchandle_get_target = mock_gchandle_get_target,
    .runtime_invoke = mock_runtime_invoke,
    .string_to_utf8 = mock_string_to_utf8,
    .string_new_len = mock_string_new_len,
    .free = mock_free,
};

pub const Domain = struct {
    attached_thread: ?MockThread = null,
    gpa: std.heap.DebugAllocator(.{
        // this will only every be used by a single thread
        .thread_safe = false,
    }) = .{},
    objects: std.SinglyLinkedList = .{},

    pub fn deinit(domain: *Domain) void {
        {
            var maybe_node = domain.objects.first;
            while (maybe_node) |node| {
                const object: *MockObject = @fieldParentPtr("list_node", node);
                const next_saved = node.next; // save before we destroy
                domain.gpa.allocator().destroy(object);
                maybe_node = next_saved;
            }
        }

        const result = domain.gpa.deinit();
        std.debug.assert(.ok == result);
    }

    pub fn new(domain: *Domain, data: MockObject.Data) *MockObject {
        const object = domain.gpa.allocator().create(MockObject) catch |e| oom(e);
        object.* = .{ .list_node = .{}, .data = data };
        domain.objects.prepend(&object.list_node);
        return object;
    }

    pub fn fromMono(domain: *const mono.Domain) *const Domain {
        return @ptrCast(@alignCast(domain));
    }
    pub fn toMono(domain: *const Domain) *const mono.Domain {
        return @ptrCast(domain);
    }
};
const MockThread = struct {
    id: std.Thread.Id,
    domain: *Domain,
    pub fn fromMono(thread: *const mono.Thread) *const MockThread {
        return @ptrCast(@alignCast(thread));
    }
    pub fn toMono(thread: *const MockThread) *const mono.Thread {
        return @ptrCast(thread);
    }
};

fn mock_get_root_domain() callconv(.c) ?*const mono.Domain {
    return (thread_local_root_domain orelse return null).toMono();
}

fn domain_get() ?*Domain {
    const domain = thread_local_root_domain orelse return null;
    const attached_thread = domain.attached_thread orelse return null;
    if (attached_thread.id != std.Thread.getCurrentId()) return null;
    return domain;
}
fn mock_domain_get() callconv(.c) ?*const mono.Domain {
    return if (domain_get()) |d| d.toMono() else null;
}
fn mock_thread_attach(d: *const mono.Domain) callconv(.c) ?*const mono.Thread {
    const domain: *Domain = @constCast(Domain.fromMono(d));
    std.debug.assert(domain.attached_thread == null);
    domain.attached_thread = .{ .domain = domain, .id = std.Thread.getCurrentId() };
    return domain.attached_thread.?.toMono();
}
fn mock_thread_detach(t: *const mono.Thread) callconv(.c) void {
    const domain = blk: {
        const thread: *const MockThread = .fromMono(t);
        const domain = thread.domain;
        std.debug.assert(thread == &thread.domain.attached_thread.?);
        break :blk domain;
    };
    domain.attached_thread.? = undefined;
    domain.attached_thread = null;
}

const MockAssembly = struct {
    name: MockAssemblyName,
    image: MockImage,
    pub fn fromMono(assembly: *const mono.Assembly) *const MockAssembly {
        return @ptrCast(@alignCast(assembly));
    }
    pub fn toMono(assembly: *const MockAssembly) *const mono.Assembly {
        return @ptrCast(assembly);
    }
};
const MockImage = struct {
    namespaces: []const Namespace,
    pub fn fromMono(image: *const mono.Image) *const MockImage {
        return @ptrCast(@alignCast(image));
    }
    pub fn toMono(image: *const MockImage) *const mono.Image {
        return @ptrCast(image);
    }
};
const Namespace = struct {
    prefix: [:0]const u8,
    classes: []const MockClass,
};

const MockAssemblyName = struct {
    cstr: [:0]const u8,
    pub fn fromMono(name: *const mono.AssemblyName) *const MockAssemblyName {
        return @ptrCast(@alignCast(name));
    }
    pub fn toMono(name: *const MockAssemblyName) *const mono.AssemblyName {
        return @ptrCast(name);
    }
};
const MockClass = struct {
    name: [:0]const u8,
    methods: []const MockMethod,
    fields: []const MockClassField,
    pub fn fromMono(class: *const mono.Class) *const MockClass {
        return @ptrCast(@alignCast(class));
    }
    pub fn toMono(class: *const MockClass) *const mono.Class {
        return @ptrCast(class);
    }
};
const MockMethod = struct {
    name: [:0]const u8,
    impl: MethodImpl,
    pub fn fromMono(method: *const mono.Method) *const MockMethod {
        return @ptrCast(@alignCast(method));
    }
    pub fn toMono(method: *const MockMethod) *const mono.Method {
        return @ptrCast(method);
    }
};
const MockClassField = struct {
    name: [:0]const u8,
    protection: mono.Protection,
    kind: Kind,

    pub const Kind = union(enum) {
        instance: MockType,
        pub fn getType(kind: *const Kind) MockType {
            return switch (kind.*) {
                .instance => |t| t,
            };
        }
    };

    pub fn fromMono(class_field: *const mono.ClassField) *const MockClassField {
        return @ptrCast(@alignCast(class_field));
    }
    pub fn toMono(class_field: *const MockClassField) *const mono.ClassField {
        return @ptrCast(class_field);
    }
};

const MethodImpl = union(enum) {
    return_void: *const fn () void,
    return_i4: *const fn () i32,
    return_static_string: *const fn () [:0]const u8,
    pub fn sig(impl: *const MethodImpl) *const MockMethodSignature {
        return switch (impl.*) {
            inline else => |_, tag| &@field(method_sigs, @tagName(tag)),
        };
    }
};

const MockValue = union(enum) {
    i4: i32,
    pub fn getType(self: *const MockValue) *const MockType {
        return switch (self.*) {
            inline else => |_, tag| &@field(MockType, @tagName(tag)),
        };
    }
};

const method_sigs = struct {
    const return_void: MockMethodSignature = .{
        .return_type = .void,
        .param_count = 0,
    };
    const return_i4: MockMethodSignature = .{
        .return_type = .i4,
        .param_count = 0,
    };
    const return_static_string: MockMethodSignature = .{
        .return_type = .string,
        .param_count = 0,
    };
};

const MockMethodSignature = struct {
    return_type: MockType,
    param_count: c_int,
    pub fn fromMono(sig: *const mono.MethodSignature) *const MockMethodSignature {
        return @ptrCast(@alignCast(sig));
    }
    pub fn toMono(sig: *const MockMethodSignature) *const mono.MethodSignature {
        return @ptrCast(sig);
    }
};
const MockType = struct {
    kind: mono.TypeKind,

    pub const @"void": MockType = .{ .kind = .void };
    pub const @"i4": MockType = .{ .kind = .i4 };
    pub const string: MockType = .{ .kind = .string };

    pub fn fromMono(t: *const mono.Type) *const MockType {
        return @ptrCast(@alignCast(t));
    }
    pub fn toMono(t: *const MockType) *const mono.Type {
        return @ptrCast(t);
    }
};

const MockObject = struct {
    list_node: std.SinglyLinkedList.Node,
    data: Data,
    pub const Data = union(enum) {
        i4: i32,
        static_string: [:0]const u8,
    };
    pub fn fromMono(t: *const mono.Object) *const MockObject {
        return @ptrCast(@alignCast(t));
    }
    pub fn toMono(t: *const MockObject) *const mono.Object {
        return @ptrCast(t);
    }
};

fn @"System.Console.WriteLine0"() void {
    if (builtin.is_test) {
        std.debug.print("monomock: suppressing WriteLine() for test\n", .{});
    } else {
        const result = std.fs.File.stdout().write("\n") catch |e| std.debug.panic(
            "write newline to stdout failed with {s}",
            .{@errorName(e)},
        );
        if (result != 1) std.debug.panic(
            "write newline to stdout returned {}",
            .{result},
        );
    }
}
fn @"System.Console.Beep"() void {
    if (builtin.os.tag == .windows) {
        const actually_beep = false;
        if (actually_beep) {
            if (0 == win32.Beep(800, 200)) std.debug.panic(
                "Beep failed, error={f}",
                .{win32.GetLastError()},
            );
            return;
        }
    }

    std.debug.print("monomock: Console Beep!\n", .{});
}
fn @"System.Environment.get_TickCount"() i32 {
    if (builtin.os.tag == .windows) {
        return @bitCast(win32.GetTickCount());
    } else {
        return @truncate(std.time.timestamp());
    }
}
fn @"System.Environment.get_MachineName"() [:0]const u8 {
    return "MonoMockDummyMachine";
}

// .{ .name = "Object", .methods = &[_]MockMethod{
//     .{ .name = ".ctor", .sig = .{
//         .return_type = .{ .kind = .object },
//         .param_count = 0,
//     } },
// } },
// .{ .name = "WriteLine", .sig = .{
//     .return_type = .{ .kind = .void },
//     .param_count = 1,
// } },
const assemblies = [_]MockAssembly{
    .{ .name = .{ .cstr = "mscorlib" }, .image = .{
        .namespaces = &[_]Namespace{
            .{ .prefix = "System", .classes = &[_]MockClass{
                .{ .name = "Int32", .methods = &[_]MockMethod{}, .fields = &[_]MockClassField{} },
                .{ .name = "Decimal", .methods = &[_]MockMethod{}, .fields = &[_]MockClassField{
                    .{ .name = "flags", .protection = .private, .kind = .{ .instance = .i4 } },
                } },
                .{ .name = "Console", .methods = &[_]MockMethod{
                    .{ .name = "WriteLine", .impl = .{ .return_void = &@"System.Console.WriteLine0" } },
                    .{ .name = "Beep", .impl = .{ .return_void = &@"System.Console.Beep" } },
                }, .fields = &[_]MockClassField{} },
                .{ .name = "Environment", .methods = &[_]MockMethod{
                    .{ .name = "get_TickCount", .impl = .{ .return_i4 = &@"System.Environment.get_TickCount" } },
                    .{ .name = "get_MachineName", .impl = .{ .return_static_string = &@"System.Environment.get_MachineName" } },
                }, .fields = &[_]MockClassField{} },
                .{ .name = "Object", .methods = &[_]MockMethod{}, .fields = &[_]MockClassField{} },
            } },
        },
    } },
    // .{ .name = .{ .cstr = "ExAssembly" }, .image = .{
    //     .namespaces = &[_]Namespace{
    //         .{ .prefix = "ExNs", .classes = &[_]MockClass{
    //             .{ .name = "ExClass", .methods = &[_]MockMethod{
    //                 .{ .name = "ExMethod", .sig = .{
    //                     .return_type = .{ .kind = .void },
    //                     .param_count = 0,
    //                 } },
    //             } },
    //         } },
    //     },
    // } },
};

fn mock_assembly_foreach(func: *const mono.Callback, user_data: ?*anyopaque) callconv(.c) void {
    for (&assemblies) |*assembly| {
        func(@ptrCast(@constCast(assembly)), user_data);
    }
}
fn mock_assembly_get_name(a: *const mono.Assembly) callconv(.c) ?*const mono.AssemblyName {
    const assembly: *const MockAssembly = .fromMono(a);
    return assembly.name.toMono();
}
fn mock_assembly_get_image(a: *const mono.Assembly) callconv(.c) ?*const mono.Image {
    const assembly: *const MockAssembly = .fromMono(a);
    return assembly.image.toMono();
}
fn mock_assembly_name_get_name(n: *const mono.AssemblyName) callconv(.c) ?[*:0]const u8 {
    const name: *const MockAssemblyName = .fromMono(n);
    return name.cstr;
}
fn mock_class_from_name(
    image_opaque: *const mono.Image,
    namespace_ptr: [*:0]const u8,
    name_ptr: [*:0]const u8,
) callconv(.c) ?*const mono.Class {
    const image: *const MockImage = .fromMono(image_opaque);

    const wanted_namespace = std.mem.span(namespace_ptr);
    const wanted_name = std.mem.span(name_ptr);

    const namespace = for (image.namespaces) |*namespace| {
        if (std.mem.eql(u8, namespace.prefix, wanted_namespace)) break namespace;
    } else return null;

    return for (namespace.classes) |*class| {
        if (std.mem.eql(u8, class.name, wanted_name)) return class.toMono();
    } else null;
}
fn mock_class_get_method_from_name(
    c: *const mono.Class,
    name_ptr: [*:0]const u8,
    param_count: c_int,
) callconv(.c) ?*const mono.Method {
    const class: *const MockClass = .fromMono(c);
    const name = std.mem.span(name_ptr);
    for (class.methods) |*method| {
        if (method.impl.sig().param_count != param_count) continue;
        if (std.mem.eql(u8, method.name, name)) return method.toMono();
    }
    return null;
}
fn mock_class_get_field_from_name(
    c: *const mono.Class,
    name_ptr: [*:0]const u8,
) callconv(.c) ?*const mono.ClassField {
    const class: *const MockClass = .fromMono(c);
    const name = std.mem.span(name_ptr);
    for (class.fields) |*field| {
        if (std.mem.eql(u8, field.name, name)) return field.toMono();
    }
    return null;
}

fn mock_field_get_flags(f: *const mono.ClassField) callconv(.c) mono.ClassFieldFlags {
    const field: *const MockClassField = .fromMono(f);
    return switch (field.kind) {
        .instance => .{
            .protection = field.protection,
            .static = false,
            .init_only = false, // TODO
            .literal = true, // TODO
            .not_serialized = false,
            .special_name = false,
            .unused1 = 0,
            .pin_marshal_rts = false,
            .has_field_rva = false,
            .has_default = false,
            .reserved_mask = 0,
        },
    };
}
fn mock_field_get_type(f: *const mono.ClassField) callconv(.c) *const mono.Type {
    const field: *const MockClassField = .fromMono(f);
    return field.kind.getType().toMono();
}
fn mock_field_get_value(
    maybe_obj: ?*const mono.Object,
    f: *const mono.ClassField,
    out_value: *anyopaque,
) callconv(.c) void {
    if (maybe_obj != null) @panic("todo: non-static fields");
    const field: *const MockClassField = .fromMono(f);
    _ = field;
    _ = out_value;
    @panic("todo");
}

fn mock_method_get_flags(
    method_opaque: *const mono.Method,
    iflags: ?*mono.MethodFlags,
) callconv(.c) mono.MethodFlags {
    const method: *const MockMethod = @ptrCast(@alignCast(method_opaque));
    _ = method;
    _ = iflags;
    return .{ .protection = .public, .static = true };
}

fn mock_method_signature(method_opaque: *const mono.Method) callconv(.c) ?*const mono.MethodSignature {
    const method: *const MockMethod = @ptrCast(@alignCast(method_opaque));
    return method.impl.sig().toMono();
}

fn mock_method_get_class(method_opaque: *const mono.Method) callconv(.c) ?*const mono.Class {
    const method: *const MockMethod = @ptrCast(@alignCast(method_opaque));
    for (assemblies) |assembly| {
        _ = assembly;
        _ = method;
    }
    @panic("todo");
}

fn mock_signature_get_return_type(s: *const mono.MethodSignature) callconv(.c) ?*const mono.Type {
    const sig: *const MockMethodSignature = .fromMono(s);
    return sig.return_type.toMono();
}

fn mock_signature_get_params(
    s: *const mono.MethodSignature,
    iter: *?*anyopaque,
) callconv(.c) ?*const mono.Type {
    const sig: *const MockMethodSignature = .fromMono(s);
    if (sig.param_count > 0) @panic("todo");
    _ = iter;
    return null;
}

fn mock_type_get_type(type_opaque: *const mono.Type) callconv(.c) mono.TypeKind {
    const t: *const MockType = .fromMono(type_opaque);
    return t.kind;
}

fn mock_object_new(
    domain: *const mono.Domain,
    class: *const mono.Class,
) callconv(.c) ?*const mono.Object {
    _ = domain;
    _ = class;
    return null;
}

fn mock_object_unbox(o: *const mono.Object) callconv(.c) *anyopaque {
    const object: *const MockObject = .fromMono(o);
    return switch (object.data) {
        .i4 => |*value| @ptrCast(@constCast(value)),
        .static_string => @panic("codebug?"),
    };
}

fn mock_gchandle_new(o: *const mono.Object, pinned: i32) callconv(.c) mono.GcHandle {
    _ = o;
    _ = pinned;
    @panic("todo");
}
fn mock_gchandle_free(handle: mono.GcHandle) callconv(.c) void {
    _ = handle;
    @panic("todo");
}
fn mock_gchandle_get_target(handle: mono.GcHandle) callconv(.c) *const mono.Object {
    _ = handle;
    @panic("todo");
}

fn mock_runtime_invoke(
    method_opaque: *const mono.Method,
    obj: ?*anyopaque,
    params: ?**anyopaque,
    exception: ?*?*const mono.Object,
) callconv(.c) ?*const mono.Object {
    const method: *const MockMethod = .fromMono(method_opaque);
    // std.debug.print("monomock: MockMethod '{s}' has been called\n", .{method.name});
    if (method.impl.sig().param_count != 0) @panic("todo: implement params");
    _ = obj;
    _ = params;
    _ = exception;
    const domain = domain_get().?;
    switch (method.impl) {
        .return_void => |f| {
            f();
            return null;
        },
        .return_i4 => |f| return domain.new(.{ .i4 = f() }).toMono(),
        .return_static_string => |f| {
            return domain.new(.{ .static_string = f() }).toMono();
        },
    }
}

fn mock_string_to_utf8(object_mono: *const mono.Object) callconv(.c) ?[*:0]const u8 {
    const object: *const MockObject = .fromMono(object_mono);
    _ = object;
    @panic("todo");
}

fn mock_string_new_len(
    d: *const mono.Domain,
    text: [*]const u8,
    len: c_uint,
) callconv(.c) ?*const mono.String {
    const domain: *const Domain = .fromMono(d);
    _ = domain;
    _ = text;
    _ = len;
    @panic("todo");
}

fn mock_free(ptr: *anyopaque) callconv(.c) void {
    _ = ptr;
    @panic("todo");
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const mono = @import("mono.zig");
