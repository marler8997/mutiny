pub const funcs: mono.Funcs = .{
    .get_root_domain = test_get_root_domain,
    .thread_attach = test_thread_attach,
    .assembly_foreach = test_assembly_foreach,
    .assembly_get_name = test_assembly_get_name,
    .assembly_get_image = test_assembly_get_image,
    .assembly_name_get_name = test_assembly_name_get_name,
    .class_from_name = test_class_from_name,
    .class_get_method_from_name = test_class_get_method_from_name,
    .method_signature = test_method_signature,
    .signature_get_params = test_signature_get_params,
};
fn test_get_root_domain() callconv(.c) ?*const mono.Domain {
    return null;
}
fn test_thread_attach(_: ?*const mono.Domain) callconv(.c) ?*const mono.Thread {
    return null;
}
const TestAssembly = struct {
    name: TestAssemblyName,
    image: TestImage,
    pub fn fromMono(assembly: *const mono.Assembly) *const TestAssembly {
        return @ptrCast(@alignCast(assembly));
    }
    pub fn toMono(assembly: *const TestAssembly) *const mono.Assembly {
        return @ptrCast(assembly);
    }
};
const TestImage = struct {
    namespaces: []const Namespace,
    pub fn fromMono(image: *const mono.Image) *const TestImage {
        return @ptrCast(@alignCast(image));
    }
    pub fn toMono(image: *const TestImage) *const mono.Image {
        return @ptrCast(image);
    }
};
const Namespace = struct {
    prefix: [:0]const u8,
    classes: []const TestClass,
};

const TestAssemblyName = struct {
    cstr: [:0]const u8,
    pub fn fromMono(name: *const mono.AssemblyName) *const TestAssemblyName {
        return @ptrCast(@alignCast(name));
    }
    pub fn toMono(name: *const TestAssemblyName) *const mono.AssemblyName {
        return @ptrCast(name);
    }
};
const TestClass = struct {
    name: [:0]const u8,
    methods: []const TestMethod,
    pub fn fromMono(class: *const mono.Class) *const TestClass {
        return @ptrCast(@alignCast(class));
    }
    pub fn toMono(class: *const TestClass) *const mono.Class {
        return @ptrCast(class);
    }
};
const TestMethod = struct {
    name: [:0]const u8,
    sig: TestMethodSignature,
    pub fn fromMono(method: *const mono.Method) *const TestMethod {
        return @ptrCast(@alignCast(method));
    }
    pub fn toMono(method: *const TestMethod) *const mono.Method {
        return @ptrCast(method);
    }
};
const TestMethodSignature = struct {
    param_count: c_int,
    pub fn fromMono(sig: *const mono.MethodSignature) *const TestMethodSignature {
        return @ptrCast(@alignCast(sig));
    }
    pub fn toMono(sig: *const TestMethodSignature) *const mono.MethodSignature {
        return @ptrCast(sig);
    }
};

const assemblies = [_]TestAssembly{
    .{ .name = .{ .cstr = "mscorlib" }, .image = .{
        .namespaces = &[_]Namespace{
            .{ .prefix = "System", .classes = &[_]TestClass{
                .{ .name = "Console", .methods = &[_]TestMethod{
                    .{ .name = "WriteLine", .sig = .{ .param_count = 0 } },
                } },
            } },
        },
    } },
    .{ .name = .{ .cstr = "ExAssembly" }, .image = .{
        .namespaces = &[_]Namespace{
            .{ .prefix = "ExNs", .classes = &[_]TestClass{
                .{ .name = "ExClass", .methods = &[_]TestMethod{
                    .{ .name = "ExMethod", .sig = .{ .param_count = 0 } },
                } },
            } },
        },
    } },
};

fn test_assembly_foreach(func: *const mono.Callback, user_data: ?*anyopaque) callconv(.c) void {
    for (&assemblies) |*assembly| {
        func(@ptrCast(@constCast(assembly)), user_data);
    }
}
fn test_assembly_get_name(a: *const mono.Assembly) callconv(.c) ?*const mono.AssemblyName {
    const assembly: *const TestAssembly = .fromMono(a);
    return assembly.name.toMono();
}
fn test_assembly_get_image(a: *const mono.Assembly) callconv(.c) ?*const mono.Image {
    const assembly: *const TestAssembly = .fromMono(a);
    return assembly.image.toMono();
}
fn test_assembly_name_get_name(n: *const mono.AssemblyName) callconv(.c) ?[*:0]const u8 {
    const name: *const TestAssemblyName = .fromMono(n);
    return name.cstr;
}
fn test_class_from_name(
    image_opaque: *const mono.Image,
    namespace_ptr: [*:0]const u8,
    name_ptr: [*:0]const u8,
) callconv(.c) ?*const mono.Class {
    const image: *const TestImage = .fromMono(image_opaque);

    const wanted_namespace = std.mem.span(namespace_ptr);
    const wanted_name = std.mem.span(name_ptr);

    const namespace = for (image.namespaces) |*namespace| {
        if (std.mem.eql(u8, namespace.prefix, wanted_namespace)) break namespace;
    } else return null;

    return for (namespace.classes) |*class| {
        if (std.mem.eql(u8, class.name, wanted_name)) return class.toMono();
    } else null;
}
fn test_class_get_method_from_name(
    c: *const mono.Class,
    name_ptr: [*:0]const u8,
    param_count: c_int,
) callconv(.c) ?*const mono.Method {
    const class: *const TestClass = .fromMono(c);
    const name = std.mem.span(name_ptr);
    for (class.methods) |*method| {
        if (method.sig.param_count != param_count) continue;
        if (std.mem.eql(u8, method.name, name)) return method.toMono();
    }
    return null;
}

fn test_method_signature(method_opaque: *const mono.Method) callconv(.c) ?*const mono.MethodSignature {
    const method: *const TestMethod = @ptrCast(@alignCast(method_opaque));
    return method.sig.toMono();
}

fn test_signature_get_params(
    s: *const mono.MethodSignature,
    iter: *?*anyopaque,
) callconv(.c) ?*const mono.Type {
    const sig: *const TestMethodSignature = .fromMono(s);
    if (sig.param_count > 0) @panic("todo");
    _ = iter;
    return null;
}

const std = @import("std");
const mono = @import("mono.zig");
