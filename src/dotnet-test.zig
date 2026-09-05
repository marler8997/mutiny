pub const enable_mutiny_test_class = true;

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

    const dotnet_kind: dotnet.Kind = blk: {
        const basename = std.fs.path.basename(dll);
        if (std.mem.eql(u8, basename, dotnet.dll_name_mono)) break :blk .mono;
        if (std.mem.eql(u8, basename, dotnet.dll_name_il2cpp)) break :blk .il2cpp;
        errExit(
            "unable to determine dotnet kind, dll is named neither '{s}' nor '{s}'",
            .{ dotnet.dll_name_mono, dotnet.dll_name_il2cpp },
        );
    };
    switch (dotnet_kind) {
        .mono => {
            if (opt.data_dir != null) errExit("--data-dir invalid for mono", .{});
        },
        .il2cpp => {
            if (opt.assembly_path != null) errExit("--assembly-path invalid for il2cpp", .{});
        },
    }

    const module = dynlib.load(dll) catch |err| switch (err) {
        error.NotFound => errExit("'{s}' or one of its dependencies was not found", .{dll}),
        error.Unexpected => @panic("unexpected error, see log"),
    };

    const dotnet_funcs: dotnet.Funcs = blk: {
        var missing_proc: [:0]const u8 = undefined;
        break :blk dotnet.Funcs.init(&missing_proc, dotnet_kind, module) catch errExit(
            "'{s}' is missing proc '{s}'",
            .{ dll, missing_proc },
        );
    };

    const root_domain: *const dotnet.Domain = blk: switch (dotnet_kind) {
        .mono => {
            const init_funcs: MonoInitFuncs = funcs: {
                var missing_proc: [:0]const u8 = undefined;
                break :funcs MonoInitFuncs.init(&missing_proc, module) catch errExit(
                    "'{s}' is missing proc '{s}'",
                    .{ dll, missing_proc },
                );
            };

            if (opt.assembly_path) |path| {
                init_funcs.set_assemblies_path(path);
            }

            std.log.info("mono_jit_init...", .{});
            const result = init_funcs.jit_init("dotnet-test") orelse errExit(
                "mono_jit_init failed",
                .{},
            );
            std.log.info("mono_jit_init success", .{});
            loadTestAssembly(init_funcs);
            break :blk result;
        },
        .il2cpp => {
            const init_funcs: Il2cppInitFuncs = funcs: {
                var missing_proc: [:0]const u8 = undefined;
                break :funcs Il2cppInitFuncs.getFuncs(&missing_proc, module) catch errExit(
                    "'{s}' is missing proc '{s}'",
                    .{ dll, missing_proc },
                );
            };

            // init_funcs.register_log_callback((struct {
            //     pub fn log(m: [*:0]const u8) callconv(.c) void {
            //         std.log.info("IL2CPP: {s}", .{std.mem.span(m)});
            //     }
            // }).log);

            if (opt.data_dir) |dir| {
                init_funcs.set_data_dir(dir);
            }

            std.log.info("il2cpp_init...", .{});
            init_funcs.init("dotnet-test");
            const domain = dotnet_funcs.get_root_domain() orelse errExit(
                "mono_get_root_domain returned NULL",
                .{},
            );
            testDetour(&dotnet_funcs, module, domain);
            break :blk domain;
        },
    };

    const thread = dotnet_funcs.thread_attach(root_domain) orelse errExit("mono_thread_attach failed", .{});
    std.log.info("thread attach success 0x{x}", .{@intFromPtr(thread)});

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(dotnet_funcs.domain_get() == root_domain);

    Vm.runTests(&dotnet_funcs, findUnityVersion(arena, dll)) catch |err| {
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
fn testDetour(funcs: *const dotnet.Funcs, module: dynlib.Module, domain: *const dotnet.Domain) void {
    const target = detour.findFunction(module, "il2cpp_class_from_il2cpp_type") catch |e|
        errExit("locate Class::FromIl2CppType: {s}", .{@errorName(e)});
    std.log.info("detour: Class::FromIl2CppType at 0x{x}", .{target});

    const object = findClassByName(funcs, domain, "System", "Object") orelse errExit("no System.Object", .{});
    const object_type = funcs.class_get_type(object);
    const from_type: *const fn (*const dotnet.Type) callconv(.c) ?*const dotnet.Class =
        @ptrCast(dynlib.getProc(module, "il2cpp_class_from_il2cpp_type") catch unreachable);
    const before = from_type(object_type);

    const installed = detour.install(target, @intFromPtr(&fromIl2CppTypeHook)) catch |e|
        errExit("detour install: {s}", .{@errorName(e)});
    fromIl2CppTypeOrig = @ptrFromInt(installed.trampoline);

    const after = from_type(object_type);
    if (after != before or after != object)
        errExit("pass-through detour changed class_from_il2cpp_type result", .{});
    std.log.info("detour: pass-through hook validated -- resolves the same class through the trampoline", .{});
}

fn findClassByName(
    funcs: *const dotnet.Funcs,
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

const FromIl2CppType = *const fn (*const dotnet.Type, bool) callconv(.c) ?*const dotnet.Class;
var fromIl2CppTypeOrig: FromIl2CppType = undefined;
fn fromIl2CppTypeHook(t: *const dotnet.Type, throw_on_error: bool) callconv(.c) ?*const dotnet.Class {
    return fromIl2CppTypeOrig(t, throw_on_error);
}

const Il2cppInitFuncs = struct {
    register_log_callback: *const fn (*const fn ([*:0]const u8) callconv(.c) void) void,
    set_data_dir: *const fn (path: [*:0]const u8) callconv(.c) void,
    init: *const fn (name: [*:0]const u8) callconv(.c) void,
    pub fn getFuncs(proc_ref: *[:0]const u8, mod: dynlib.Module) error{ProcNotFound}!Il2cppInitFuncs {
        return .{
            .register_log_callback = try il2cpp_funcs.il2cppGet(mod, .register_log_callback, proc_ref),
            .set_data_dir = try il2cpp_funcs.il2cppGet(mod, .set_data_dir, proc_ref),
            .init = try il2cpp_funcs.il2cppGet(mod, .init, proc_ref),
        };
    }
};

// functions that aren't needed by the injected Mutiny.dll but are needed to initialize
// mono for this test executable.
const MonoInitFuncs = struct {
    jit_init: *const fn (name: [*:0]const u8) callconv(.c) ?*const dotnet.Domain,
    set_assemblies_path: *const fn ([*:0]const u8) callconv(.c) void,
    image_open_from_data: *const fn (
        data: [*]const u8,
        data_len: u32,
        need_copy: i32,
        status: *MonoImageOpenStatus,
    ) callconv(.c) ?*const dotnet.Image,
    assembly_load_from: *const fn (
        image: *const dotnet.Image,
        name: [*:0]const u8,
        status: *MonoImageOpenStatus,
    ) callconv(.c) ?*const dotnet.Assembly,
    pub fn init(proc_ref: *[:0]const u8, mod: dynlib.Module) error{ProcNotFound}!MonoInitFuncs {
        return .{
            .jit_init = try mono_funcs.monoGet(mod, .jit_init, proc_ref),
            .set_assemblies_path = try mono_funcs.monoGet(mod, .set_assemblies_path, proc_ref),
            .image_open_from_data = try mono_funcs.monoGet(mod, .image_open_from_data, proc_ref),
            .assembly_load_from = try mono_funcs.monoGet(mod, .assembly_load_from, proc_ref),
        };
    }
};

const MonoImageOpenStatus = enum(c_int) {
    ok = 0,
    error_errno = 1,
    image_invalid = 2,
    missing_assemblyref = 3,
    _,
};

const mutiny_test_dll = @embedFile("mutiny_test_dll");

fn loadTestAssembly(init_funcs: MonoInitFuncs) void {
    var status: MonoImageOpenStatus = .ok;
    const image = init_funcs.image_open_from_data(
        mutiny_test_dll,
        @intCast(mutiny_test_dll.len),
        1,
        &status,
    ) orelse errExit("mono_image_open_from_data failed with {t}", .{status});
    if (status != .ok) errExit("mono_image_open_from_data gave status {t}", .{status});
    _ = init_funcs.assembly_load_from(image, "MutinyTest", &status) orelse errExit(
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
const mono_funcs = @import("dotnetload.zig").template(MonoInitFuncs);
const il2cpp_funcs = @import("dotnetload.zig").template(Il2cppInitFuncs);

const UnityVersion = @import("UnityVersion.zig");
const Vm = @import("Vm.zig");
