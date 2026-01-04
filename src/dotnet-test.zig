pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    var opt: struct {
        assembly_path: ?[:0]const u8 = null,
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
            \\    GameAssembly.dll and you shouldn't need an assembly-path.
            \\
        );
        std.process.exit(0xff);
    }
    if (args.len != 1) errExit(
        "expected 1 non-option cmdline arg (the DLL) but got {}",
        .{args.len},
    );
    const dll = args[0];
    const module = win32.LoadLibraryA(dll) orelse errExit(
        "LoadLibrary '{s}' failed, error={f}",
        .{ dll, win32.GetLastError() },
    );

    const dotnet_funcs: dotnet.Funcs = blk: {
        var missing_proc: [:0]const u8 = undefined;
        break :blk dotnet.Funcs.init(&missing_proc, module) catch errExit(
            "'{s}' is missing proc '{s}'",
            .{ dll, missing_proc },
        );
    };

    const root_domain = blk: {
        const init_funcs: DotnetInitFuncs = funcs: {
            var missing_proc: [:0]const u8 = undefined;
            break :funcs DotnetInitFuncs.init(&missing_proc, module) catch errExit(
                "'{s}' is missing proc '{s}'",
                .{ dll, missing_proc },
            );
        };

        if (opt.assembly_path) |path| {
            init_funcs.set_assemblies_path(path);
        }

        std.log.info("mono_jit_init...", .{});
        break :blk init_funcs.jit_init("dotnet-test") orelse errExit(
            "mono_jit_init failed",
            .{},
        );
    };
    std.log.info("mono_jit_init success", .{});

    const thread = dotnet_funcs.thread_attach(root_domain) orelse errExit("mono_thread_attach failed", .{});
    std.log.info("thread attach success 0x{x}", .{@intFromPtr(thread)});

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(dotnet_funcs.domain_get() == root_domain);

    Vm.runTests(&dotnet_funcs) catch |err| {
        std.log.err("tests failed with {s}:", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        } else {
            std.log.err("    no error trace", .{});
        }
    };
    std.log.info("dotnet-test: success", .{});
}

// functions that aren't needed by the injected Mutiny.dll but are needed to initialize
// mono for this test executable.
const DotnetInitFuncs = struct {
    jit_init: *const fn (name: [*:0]const u8) callconv(.c) ?*const dotnet.Domain,
    set_assemblies_path: *const fn ([*:0]const u8) callconv(.c) void,
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!DotnetInitFuncs {
        return .{
            .jit_init = try dotnetload.get(mod, .jit_init, proc_ref),
            .set_assemblies_path = try dotnetload.get(mod, .set_assemblies_path, proc_ref),
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
const dotnetload = @import("dotnetload.zig").template(DotnetInitFuncs);
const Vm = @import("Vm.zig");
