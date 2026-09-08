pub const Error = LoadError || InstantiateError;

pub const LoadError = error{
    ImageOpenFailed,
    AssemblyLoadFailed,
    MissingClass,
};

pub fn load(dotnet_funcs: *const dotnet.Funcs) LoadError!*const dotnet.Class {
    const mono = &dotnet_funcs.kind.mono;

    var status: dotnet.MonoImageOpenStatus = .ok;
    const image = mono.image_open_from_data(
        mutiny_mono_dll.ptr,
        @intCast(mutiny_mono_dll.len),
        1,
        &status,
    ) orelse {
        std.log.err("mono_image_open_from_data(MutinyMono.dll) returned null with status {t}", .{status});
        return error.ImageOpenFailed;
    };
    if (status != .ok) {
        std.log.err("mono_image_open_from_data(MutinyMono.dll) gave status {t}", .{status});
        return error.ImageOpenFailed;
    }
    _ = mono.assembly_load_from(image, "MutinyMono", &status) orelse {
        std.log.err("mono_assembly_load_from(MutinyMono) returned null with status {t}", .{status});
        return error.AssemblyLoadFailed;
    };
    if (status != .ok) {
        std.log.err("mono_assembly_load_from(MutinyMono) gave status {t}", .{status});
        return error.AssemblyLoadFailed;
    }
    const on_update: *const fn () callconv(.c) void = options.onUpdate;
    mono.add_internal_call("Mutiny.Ticker::OnUpdate", @ptrCast(on_update));
    const on_gui: *const fn () callconv(.c) void = options.onGui;
    mono.add_internal_call("Mutiny.Ticker::OnGui", @ptrCast(on_gui));

    return dotnet_funcs.class_from_name(image, "Mutiny", "Ticker") orelse {
        std.log.err("MutinyMono.dll has no Mutiny.Ticker class", .{});
        return error.MissingClass;
    };
}

pub const InstantiateError = error{
    MissingAssembly,
    MissingClass,
    MissingMethod,
    ObjectNewFailed,
    TypeObjectFailed,
    ManagedException,
    AddComponentReturnedNull,
    AddComponentWrongClass,
};

pub fn instantiate(funcs: *const dotnet.Funcs, ticker: *const dotnet.Class) InstantiateError!void {
    const core = findImage(funcs, "UnityEngine.CoreModule") orelse return error.MissingAssembly;
    const game_object_class = findClass(funcs, core, "UnityEngine", "GameObject") orelse return error.MissingClass;
    const object_class = findClass(funcs, core, "UnityEngine", "Object") orelse return error.MissingClass;
    const ctor = findMethod(funcs, game_object_class, ".ctor", 0) orelse return error.MissingMethod;
    const dont_destroy = findMethod(funcs, object_class, "DontDestroyOnLoad", 1) orelse return error.MissingMethod;
    const add_component = findMethod(funcs, game_object_class, "AddComponent", 1) orelse return error.MissingMethod;

    const game_object = funcs.object_new(game_object_class) orelse return error.ObjectNewFailed;
    _ = try invoke(funcs, "GameObject..ctor", ctor, game_object, null);

    var dont_destroy_args = [_]*anyopaque{@constCast(game_object)};
    _ = try invoke(funcs, "Object.DontDestroyOnLoad", dont_destroy, null, @ptrCast(&dont_destroy_args));

    const type_object = funcs.type_get_object(funcs.class_get_type(ticker)) orelse return error.TypeObjectFailed;
    var add_component_args = [_]*anyopaque{@constCast(type_object)};
    const component = try invoke(funcs, "GameObject.AddComponent", add_component, game_object, @ptrCast(&add_component_args)) orelse
        return error.AddComponentReturnedNull;

    const component_class = funcs.object_get_class(component);
    std.log.info("mono MonoBehaviour: AddComponent returned {*} of class {s}{s}", .{
        component,
        funcs.class_get_name(component_class),
        if (component_class == ticker) " (ours)" else " (NOT ours)",
    });
    if (component_class != ticker) return error.AddComponentWrongClass;

    const behaviour_class = findClass(funcs, core, "UnityEngine", "MonoBehaviour") orelse return error.MissingClass;
    if (funcs.class_get_method_from_name(behaviour_class, "set_useGUILayout", 1)) |set_use_gui_layout| {
        var value: bool = false;
        var args = [_]*anyopaque{@ptrCast(&value)};
        _ = try invoke(funcs, "MonoBehaviour.set_useGUILayout", set_use_gui_layout, component, @ptrCast(&args));
    } else {
        std.log.warn("MonoBehaviour.set_useGUILayout is missing, the GUI layout pass stays enabled", .{});
    }
}

fn findClass(funcs: *const dotnet.Funcs, image: *const dotnet.Image, namespace: [*:0]const u8, name: [*:0]const u8) ?*const dotnet.Class {
    return funcs.class_from_name(image, namespace, name) orelse {
        std.log.err("class {s}.{s} not found in {s}", .{ namespace, name, funcs.kind.mono.image_get_filename(image) orelse "?" });
        return null;
    };
}

fn findMethod(funcs: *const dotnet.Funcs, class: *const dotnet.Class, name: [*:0]const u8, param_count: c_int) ?*const dotnet.Method {
    return funcs.class_get_method_from_name(class, name, param_count) orelse {
        std.log.err("method {s}.{s}/{} not found", .{ funcs.class_get_name(class), name, param_count });
        return null;
    };
}

fn invoke(
    funcs: *const dotnet.Funcs,
    what: []const u8,
    method: *const dotnet.Method,
    obj: ?*const dotnet.Object,
    params: ?**anyopaque,
) InstantiateError!?*const dotnet.Object {
    var exception: ?*const dotnet.Object = null;
    const result = funcs.runtime_invoke(method, obj, params, &exception);
    if (exception) |e| {
        std.log.err("{s} threw {s}", .{ what, funcs.class_get_name(funcs.object_get_class(e)) });
        return error.ManagedException;
    }
    return result;
}

const FindImage = struct {
    funcs: *const dotnet.Funcs,
    needle: []const u8,
    match: ?*const dotnet.Image = null,
};

fn findImage(funcs: *const dotnet.Funcs, needle: []const u8) ?*const dotnet.Image {
    var ctx: FindImage = .{ .funcs = funcs, .needle = needle };
    funcs.kind.mono.assembly_foreach(&findImageCallback, &ctx);
    return ctx.match;
}

fn findImageCallback(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *const dotnet.Assembly = @ptrCast(assembly_opaque);
    const ctx: *FindImage = @ptrCast(@alignCast(user_data));
    if (ctx.match != null) return;
    const mono = &ctx.funcs.kind.mono;
    const name = mono.assembly_get_name(assembly) orelse return;
    const str = mono.assembly_name_get_name(name) orelse return;
    if (!std.mem.eql(u8, std.mem.span(str), ctx.needle)) return;
    ctx.match = ctx.funcs.assembly_get_image(assembly);
}

const mutiny_mono_dll = @embedFile("mutiny_mono_dll");

const std = @import("std");
const dotnet = @import("dotnet.zig");
const options = @import("mutiny.zig").options;
