pub const enable_mutiny_test_class = true;

pub const mutiny_options: @import("mutiny.zig").Options = .{
    .onUpdate = onMutinyUpdate,
    .onGui = onMutinyGui,
};

var mutiny_update_called: bool = false;
const UpdateCursor = struct {};
pub fn testMutinyUpdateCursor() UpdateCursor {
    std.debug.assert(!mutiny_update_called);
    return .{};
}
pub fn testMutinyUpdateCalled(cursor: UpdateCursor) bool {
    _ = cursor;
    return mutiny_update_called;
}

fn onMutinyUpdate() callconv(.c) void {
    std.debug.assert(!mutiny_update_called);
    mutiny_update_called = true;
}
var mutiny_gui_called: bool = false;
const GuiCursor = struct {};
pub fn testMutinyGuiCursor() GuiCursor {
    std.debug.assert(!mutiny_gui_called);
    return .{};
}
pub fn testMutinyGuiCalled(cursor: GuiCursor) bool {
    _ = cursor;
    return mutiny_gui_called;
}

fn onMutinyGui() callconv(.c) void {
    std.debug.assert(!mutiny_gui_called);
    mutiny_gui_called = true;
}

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    var opt: struct {
        assembly_path: ?[:0]const u8 = null,
        data_dir: ?[:0]const u8 = null,
    } = .{};
    const args = blk: {
        const all_args = try std.process.argsAlloc(arena);
        // no need to free
        var non_option_count: usize = 0;
        var arg_index: usize = 1;
        while (arg_index < all_args.len) : (arg_index += 1) {
            const arg = all_args[arg_index];
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_count] = arg;
                non_option_count += 1;
            } else if (std.mem.eql(u8, arg, "--assembly-path")) {
                arg_index += 1;
                if (arg_index == all_args.len) errExit("--assembly-path requires an arg", .{});
                opt.assembly_path = all_args[arg_index];
            } else if (std.mem.eql(u8, arg, "--data-dir")) {
                arg_index += 1;
                if (arg_index == all_args.len) errExit("--data-dir requires an arg", .{});
                opt.data_dir = all_args[arg_index];
            } else errExit(
                "unknown cmdline option '{s}'",
                .{arg},
            );
        }
        break :blk all_args[0..non_option_count];
    };
    if (args.len == 0) {
        try std.fs.File.stderr().writeAll(
            \\Usage: dotnet-test.exe [--assembly-path ASSEMBLY_PATH] DLL
            \\
            \\NOTE:
            \\    If the Unity game is using MONO, the DLL is probably named
            \\    mono-2.0-bdwgc.dll and you'll need to specify --assembly-path
            \\    as the dir containing mscorlib.dll.
            \\
            \\    If the Unity game is using IL2CPP, the dll is probably named
            \\    GameAssembly.dll and you'll probably need to specify --data-dir
            \\    as the dir containing Metadata/global-metadata.dat
            \\
        );
        std.process.exit(0xff);
    }
    if (args.len != 1) errExit(
        "expected 1 non-option cmdline arg (the DLL) but got {}",
        .{args.len},
    );
    const dll = args[0];

    const dotnet_kind = dotnethost.kindFromDllName(dll) orelse errExit(
        "unable to determine dotnet kind, dll is named neither '{s}' nor '{s}'",
        .{ dotnet.dll_name_mono, dotnet.dll_name_il2cpp },
    );
    std.log.info("loading the {t} runtime...", .{dotnet_kind});
    const host = dotnethost.load(Funcs, "dotnet-test", dotnet_kind, dll, .{
        .assembly_path = opt.assembly_path,
        .data_dir = opt.data_dir,
    }) catch |err| switch (err) {
        error.Reported => std.process.exit(0xff),
    };
    std.log.info("LoadLibrary: {s}", .{switch (host.loaded) {
        .directly => "SetDllDirectory not required",
        .after_set_dll_directory => "after SetDllDirectory",
    }});
    const dotnet_funcs = &host.funcs;
    switch (dotnet_funcs.kind) {
        .mono => {
            loadStubAssembly(dotnet_funcs);
            loadTestAssembly(dotnet_funcs);
        },
        .il2cpp => {
            // dotnet_funcs.kind.il2cpp.register_log_callback((struct {
            //     pub fn log(m: [*:0]const u8) callconv(.c) void {
            //         std.log.info("IL2CPP: {s}", .{std.mem.span(m)});
            //     }
            // }).log);
            testDetour(dotnet_funcs, host.module, host.domain);
        },
    }
    host.attachThread() catch |err| switch (err) {
        error.Reported => std.process.exit(0xff),
    };
    std.log.info("thread attach success", .{});

    Vm.runTests(&dotnet_funcs.tests, findUnityVersion(arena, dll)) catch |err| {
        std.log.err("tests failed with {s}:", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        } else {
            std.log.err("    no error trace", .{});
        }
        std.process.exit(0xff);
    };
    std.log.info("dotnet-test: success", .{});
}

// Locate the internal Class::FromIl2CppType, install a pass-through detour on it, and confirm the
// hooked export still resolves the same class through the trampoline -- proving the trampoline+patch
// are byte-correct before any real hook logic rides on them.
fn testDetour(funcs: *const Funcs, module: dynlib.Module, domain: *const dotnet.Domain) void {
    const target = detour.findFunction(module, "il2cpp_class_from_il2cpp_type") catch |e|
        errExit("locate Class::FromIl2CppType: {s}", .{@errorName(e)});
    std.log.info("detour: Class::FromIl2CppType at 0x{x}", .{target});

    const object = findClassByName(funcs, domain, "System", "Object") orelse errExit("no System.Object", .{});
    const object_type = funcs.class_get_type(object);
    const from_type: *const fn (*const dotnet.Type) callconv(.c) ?*const dotnet.Class =
        @ptrCast(dynlib.getProc(module, "il2cpp_class_from_il2cpp_type") catch unreachable);
    const before = from_type(object_type);

    const installed = detour.install(target, @intFromPtr(&il2cppclass.fromIl2CppTypeHook)) catch |e|
        errExit("detour install: {s}", .{@errorName(e)});
    il2cppclass.global.fromIl2CppTypeOrig = @ptrFromInt(installed.trampoline);

    const after = from_type(object_type);
    if (after != before or after != object)
        errExit("pass-through detour changed class_from_il2cpp_type result", .{});
    std.log.info("detour: pass-through hook validated -- resolves the same class through the trampoline", .{});

    const handle_target = detour.findTypeInfoFromTypeDefinitionIndex(module) catch |e|
        errExit("locate MetadataCache::GetTypeInfoFromTypeDefinitionIndex: {s}", .{@errorName(e)});
    std.log.info("detour: GetTypeInfoFromTypeDefinitionIndex at +0x{x}", .{handle_target - @intFromPtr(module)});

    const il2cpp = &funcs.kind.il2cpp;
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(domain, &assembly_count);
    const image = il2cpp.assembly_get_image(assemblies[0]);
    const class_before = il2cpp.image_get_class(image, 0);

    const handle_installed = detour.install(handle_target, @intFromPtr(&il2cppclass.typeInfoFromTypeDefinitionIndexHook)) catch |e|
        errExit("detour install (GetTypeInfoFromTypeDefinitionIndex): {s}", .{@errorName(e)});
    il2cppclass.global.typeInfoFromTypeDefinitionIndexOrig = @ptrFromInt(handle_installed.trampoline);

    const class_after = il2cpp.image_get_class(image, 0);
    if (class_after != class_before)
        errExit("pass-through GetTypeInfoFromTypeDefinitionIndex detour changed image_get_class result", .{});
    std.log.info("detour: GetTypeInfoFromTypeDefinitionIndex pass-through validated ({s})", .{funcs.class_get_name(class_after)});
}

fn findClassByName(
    funcs: *const Funcs,
    domain: *const dotnet.Domain,
    namespace: [*:0]const u8,
    name: [*:0]const u8,
) ?*const dotnet.Class {
    var count: usize = 0;
    const assemblies = funcs.kind.il2cpp.domain_get_assemblies(domain, &count);
    for (assemblies[0..count]) |assembly| {
        const image = funcs.assembly_get_image(assembly) orelse continue;
        if (funcs.class_from_name(image, namespace, name)) |class| return class;
    }
    return null;
}

const Funcs = struct {
    tests: vmtest.Funcs,
    get_root_domain: *const dotnet.shared.get_root_domain,
    domain_get: *const dotnet.shared.domain_get,
    thread_attach: *const dotnet.shared.thread_attach,
    assembly_get_image: *const dotnet.shared.assembly_get_image,
    class_from_name: *const dotnet.shared.class_from_name,
    class_get_type: *const dotnet.shared.class_get_type,
    class_get_name: *const dotnet.shared.class_get_name,
    kind: union(dotnet.Kind) {
        mono: struct {
            jit_init: *const dotnet.mono.jit_init,
            set_assemblies_path: *const dotnet.mono.set_assemblies_path,
            image_open_from_data: *const dotnet.mono.image_open_from_data,
            assembly_load_from: *const dotnet.mono.assembly_load_from,
        },
        il2cpp: struct {
            register_log_callback: *const dotnet.il2cpp.register_log_callback,
            set_data_dir: *const dotnet.il2cpp.set_data_dir,
            init: *const dotnet.il2cpp.init,
            domain_get_assemblies: *const dotnet.il2cpp.domain_get_assemblies,
            assembly_get_image: *const dotnet.il2cpp.assembly_get_image,
            image_get_class: *const dotnet.il2cpp.image_get_class,
        },
    },
};

const unity_core_stub_dll = @embedFile("unity_core_stub_dll");

fn loadStubAssembly(funcs: *const Funcs) void {
    const mono = &funcs.kind.mono;
    var status: dotnet.MonoImageOpenStatus = .ok;
    const image = mono.image_open_from_data(
        unity_core_stub_dll,
        @intCast(unity_core_stub_dll.len),
        1,
        &status,
    ) orelse errExit("mono_image_open_from_data(UnityEngine.CoreModule stub) failed with {t}", .{status});
    if (status != .ok) errExit("mono_image_open_from_data(UnityEngine.CoreModule stub) gave status {t}", .{status});
    _ = mono.assembly_load_from(image, "UnityEngine.CoreModule", &status) orelse errExit(
        "mono_assembly_load_from(UnityEngine.CoreModule stub) failed with {t}",
        .{status},
    );
    if (status != .ok) errExit("mono_assembly_load_from(UnityEngine.CoreModule stub) gave status {t}", .{status});
    std.log.info("loaded the embedded UnityEngine.CoreModule stub ({} bytes)", .{unity_core_stub_dll.len});
}

const mutiny_test_dll = @embedFile("mutiny_test_dll");

fn loadTestAssembly(funcs: *const Funcs) void {
    const mono = &funcs.kind.mono;
    var status: dotnet.MonoImageOpenStatus = .ok;
    const image = mono.image_open_from_data(
        mutiny_test_dll,
        @intCast(mutiny_test_dll.len),
        1,
        &status,
    ) orelse errExit("mono_image_open_from_data failed with {t}", .{status});
    if (status != .ok) errExit("mono_image_open_from_data gave status {t}", .{status});
    _ = mono.assembly_load_from(image, "MutinyTest", &status) orelse errExit(
        "mono_assembly_load_from failed with {t}",
        .{status},
    );
    if (status != .ok) errExit("mono_assembly_load_from gave status {t}", .{status});
    std.log.info("loaded embedded MutinyTest.dll ({} bytes)", .{mutiny_test_dll.len});
}

// UnityPlayer.dll carries the engine version, and it sits at the game root - the same dir as
// GameAssembly.dll for il2cpp, a couple up from the mono runtime - so walk up from the runtime
// dll until it turns up. mutinydll reads the same file from the loaded module in-process.
fn findUnityVersion(arena: std.mem.Allocator, dll: []const u8) UnityVersion {
    var dir: ?[]const u8 = std.fs.path.dirname(dll);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const candidate = std.fs.path.join(arena, &.{ d, "UnityPlayer.dll" }) catch |e| errExit("{t}", .{e});
        std.fs.cwd().access(candidate, .{}) catch continue;
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(arena, candidate) catch |e| errExit("{t}", .{e});
        const version = UnityVersion.fromFile(path_w) catch |err| errExit(
            "reading the unity version from '{s}' failed with {t}",
            .{ candidate, err },
        );
        std.log.info("unity version: {f} (from {s})", .{ version, candidate });
        return version;
    }
    errExit("could not find UnityPlayer.dll near '{s}' to read the unity version", .{dll});
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const detour = @import("detour.zig");
const dynlib = @import("dynlib.zig");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const dotnethost = @import("dotnethost.zig");
const vmtest = @import("vmtest.zig");

const UnityVersion = @import("UnityVersion.zig");
const Vm = @import("Vm.zig");
