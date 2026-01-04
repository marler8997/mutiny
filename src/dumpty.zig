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
            } else if (std.mem.eql(u8, arg, "--mock")) {
                Vm.is_monomock = true;
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
            \\Usage: dumpty [--assembly-path PATH] [--data-dir DIR] DLL
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

    const module = loadLibrary(dll);

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
            break :blk dotnet_funcs.get_root_domain() orelse errExit(
                "mono_get_root_domain returned NULL",
                .{},
            );
        },
    };

    const thread = dotnet_funcs.thread_attach(root_domain) orelse errExit("mono_thread_attach failed", .{});
    std.log.info("thread attach success 0x{x}", .{@intFromPtr(thread)});

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(dotnet_funcs.domain_get() == root_domain);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout_writer.interface;
    dump(&dotnet_funcs, writer) catch |err| return switch (err) {
        error.WriteFailed => return stdout_writer.err.?,
        // else => |e| e,
    };
}

const dll_suffix = ".dll";

fn dump(dotnet_funcs: *const dotnet.Funcs, writer: *std.Io.Writer) !void {
    switch (dotnet_funcs.kind) {
        .mono => @panic("todo"),
        .il2cpp => |*il2cpp| {
            var assembly_count: usize = undefined;
            const assemblies = il2cpp.domain_get_assemblies(
                dotnet_funcs.domain_get().?,
                &assembly_count,
            );
            try writer.print("{} Assemblies:\n", .{assembly_count});
            // for (0..assembly_count) |i| {
            //     const assembly = assemblies[i];
            //     const image = il2cpp.assembly_get_image(assembly);
            //     const image_name = std.mem.span(il2cpp.image_get_name(image));
            //     if (std.mem.eql(u8, image_name, "__Generated")) continue;
            //     if (!std.mem.endsWith(u8, image_name, ".dll")) std.debug.panic(
            //         "expected all image names to end with '.dll' but got '{s}'",
            //         .{image_name},
            //     );
            //     const name = image_name[0 .. image_name.len - dll_suffix.len];
            //     try writer.print("Assembly[{}] {s}\n", .{ i, name });
            // }
            for (0..assembly_count) |i| {
                const assembly = assemblies[i];
                const image = il2cpp.assembly_get_image(assembly);
                const image_name = std.mem.span(il2cpp.image_get_name(image));
                if (std.mem.eql(u8, image_name, "__Generated")) continue;
                const assembly_name = image_name[0 .. image_name.len - dll_suffix.len];
                const class_count = il2cpp.image_get_class_count(image);

                try writer.writeAll("\n");
                try writer.writeAll("========================================\n");
                try writer.print("# Assembly {s} ({} classes)\n", .{ assembly_name, class_count });
                try writer.writeAll("========================================\n");
                for (0..class_count) |class_idx| {
                    try dumpClass(dotnet_funcs, writer, il2cpp.image_get_class(image, class_idx));
                }
            }
        },
    }
    try writer.flush();
}

fn dumpClass(dotnet_funcs: *const dotnet.Funcs, writer: *std.Io.Writer, class: *const dotnet.Class) !void {
    const class_name = std.mem.span(dotnet_funcs.class_get_name(class));
    const namespace = std.mem.span(dotnet_funcs.class_get_namespace(class));
    try writer.print("## Class {s}.{s}\n", .{ namespace, class_name });
    {
        var iterator: ?*anyopaque = null;
        while (dotnet_funcs.class_get_fields(class, &iterator)) |field| {
            const name = dotnet_funcs.field_get_name(field);
            const flags = dotnet_funcs.field_get_flags(field);
            const stinst: []const u8 = if (flags.static) "static  " else "instance";
            try writer.print(" - {s} field '{s}'\n", .{ stinst, name });
        }
    }
    {
        var iterator: ?*anyopaque = null;
        while (dotnet_funcs.class_get_methods(class, &iterator)) |method| {
            const name = dotnet_funcs.method_get_name(method);
            const flags = dotnet_funcs.method_get_flags(method, null);
            const stinst: []const u8 = if (flags.static) "static  " else "instance";
            try writer.print(" - {s} method '{s}'\n", .{ stinst, name });
            switch (dotnet_funcs.kind) {
                .mono => try writer.print("    TODO: implement dump method params mono\n", .{}),
                .il2cpp => |*il2cpp| {
                    const param_count = il2cpp.method_get_param_count(method);
                    for (0..param_count) |param_index| {
                        const param_name = std.mem.span(il2cpp.method_get_param_name(method, @intCast(param_index)));
                        const t = il2cpp.method_get_param(method, @intCast(param_index));
                        const type_kind = dotnet_funcs.type_get_type(t);
                        try writer.print("     param[{}] {t} name='{s}'\n", .{ param_index, type_kind, param_name });
                    }
                },
            }
        }
    }
}

fn loadLibrary(path: [:0]u8) win32.HINSTANCE {
    if (win32.LoadLibraryA(path)) |h| {
        std.log.info("LoadLibrary: SetDllDirectory not required", .{});
        return h;
    }
    switch (win32.GetLastError()) {
        .ERROR_MOD_NOT_FOUND => {},
        else => |e| errExit(
            "LoadLibrary '{s}' failed (before SetDllDirectory), error={f}",
            .{ path, e },
        ),
    }
    const dir = std.fs.path.dirname(path) orelse errExit(
        "LoadLibrary '{s}' failed with module not found",
        .{path},
    );
    const set_dll_result = blk: {
        const save = path[dir.len];
        path[dir.len] = 0;
        defer path[dir.len] = save;
        break :blk win32.SetDllDirectoryA(path);
    };
    if (set_dll_result == 0) errExit(
        "LoadLibrary '{s}' failed with module not found and SetDllDirectory failed, error={f}",
        .{ path, win32.GetLastError() },
    );
    if (win32.LoadLibraryA(path)) |h| {
        std.log.info("LoadLibrary: after SetDllDirectory", .{});
        return h;
    }
    errExit(
        "LoadLibrary '{s}' failed (after SetDllDirectory), error={f}",
        .{ path, win32.GetLastError() },
    );
}

const Il2cppInitFuncs = struct {
    register_log_callback: *const fn (*const fn ([*:0]const u8) callconv(.c) void) void,
    set_data_dir: *const fn (path: [*:0]const u8) callconv(.c) void,
    init: *const fn (name: [*:0]const u8) callconv(.c) void,
    pub fn getFuncs(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!Il2cppInitFuncs {
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
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!MonoInitFuncs {
        return .{
            .jit_init = try mono_funcs.monoGet(mod, .jit_init, proc_ref),
            .set_assemblies_path = try mono_funcs.monoGet(mod, .set_assemblies_path, proc_ref),
        };
    }
};

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const win32 = @import("win32").everything;
const dotnet = @import("dotnet.zig");
const mono_funcs = @import("dotnetload.zig").template(MonoInitFuncs);
const il2cpp_funcs = @import("dotnetload.zig").template(Il2cppInitFuncs);
const Vm = @import("Vm.zig");
