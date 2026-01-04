pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    // no need to free

    if (all_args.len <= 1) {
        try std.fs.File.stderr().writeAll(
            \\Usage: monotest.exe MONO_DLL MONO_DIR
            \\
            \\   note: MONO_DLL is probably named mono-2.0-bdwgc.dll
            \\         MONO_DIR will contain mscorlib.dll
            \\
        );
        std.process.exit(0xff);
    }
    const args = all_args[1..];
    if (args.len != 2) errExit(
        "expected 2 cmdline args (MONO_DLL/MONO_DIR) but got {}",
        .{args.len},
    );
    const mono_dll = args[0];
    const mono_dir = args[1];

    const mono_mod = win32.LoadLibraryA(mono_dll) orelse errExit(
        "LoadLibrary '{s}' failed, error={f}",
        .{ mono_dll, win32.GetLastError() },
    );

    const mono_funcs: mono.Funcs = blk: {
        var missing_proc: [:0]const u8 = undefined;
        break :blk mono.Funcs.init(&missing_proc, mono_mod) catch errExit(
            "the mono dll '{s}' is missing proc '{s}'",
            .{ mono_dll, missing_proc },
        );
    };

    const root_domain = blk: {
        const init_funcs: MonoInitFuncs = funcs: {
            var missing_proc: [:0]const u8 = undefined;
            break :funcs MonoInitFuncs.init(&missing_proc, mono_mod) catch errExit(
                "the mono dll '{s}' is missing proc '{s}'",
                .{ mono_dll, missing_proc },
            );
        };

        init_funcs.set_assemblies_path(mono_dir);

        break :blk init_funcs.jit_init("monotest") orelse errExit(
            "mono_jit_init failed",
            .{},
        );
    };

    const thread = mono_funcs.thread_attach(root_domain) orelse errExit("mono_thread_attach failed", .{});
    std.log.info("thread attach success 0x{x}", .{@intFromPtr(thread)});

    // domain_get is how the Vm accesses the domain, make sure it's
    // what we expect after attaching our thread to it
    std.debug.assert(mono_funcs.domain_get() == root_domain);

    if (std.mem.eql(u8, mono_dir, "MOCK_MONO_PATH")) {
        Vm.is_monomock = true;
    }
    Vm.runTests(&mono_funcs) catch |err| {
        std.log.err("tests failed with {s}:", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        } else {
            std.log.err("    no error trace", .{});
        }
    };
    std.log.info("monotest: success", .{});
}

// functions that aren't needed by the injected Mutiny.dll but are needed to initialize
// mono for this test executable.
const MonoInitFuncs = struct {
    jit_init: *const fn (name: [*:0]const u8) callconv(.c) ?*const mono.Domain,
    set_assemblies_path: *const fn ([*:0]const u8) callconv(.c) void,
    pub fn init(proc_ref: *[:0]const u8, mod: win32.HINSTANCE) error{ProcNotFound}!MonoInitFuncs {
        return .{
            .jit_init = try monoload.get(mod, .jit_init, proc_ref),
            .set_assemblies_path = try monoload.get(mod, .set_assemblies_path, proc_ref),
        };
    }
};

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const win32 = @import("win32").everything;
const mono = @import("mono.zig");
const monoload = @import("monoload.zig").template(MonoInitFuncs);
const Vm = @import("Vm.zig");
