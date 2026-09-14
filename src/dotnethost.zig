pub const Options = struct {
    assembly_path: ?[:0]const u8 = null,
    data_dir: ?[:0]const u8 = null,
};

pub fn Host(comptime Funcs: type) type {
    return struct {
        const Self = @This();

        module: dynlib.Module,
        loaded: Loaded,
        funcs: Funcs,
        domain: *const dotnet.Domain,

        pub fn attachThread(host: *const Self) error{Reported}!void {
            _ = host.funcs.thread_attach(host.domain) orelse return fail("thread_attach failed", .{});
            if (host.funcs.domain_get() != host.domain) return fail(
                "domain_get does not return the root domain after thread_attach",
                .{},
            );
        }
    };
}

pub const Loaded = enum {
    directly,
    after_set_dll_directory,
};

pub fn kindFromDllName(dll: []const u8) ?dotnet.Kind {
    const basename = std.fs.path.basename(dll);
    if (std.mem.eql(u8, basename, dotnet.dll_name_mono)) return .mono;
    if (std.mem.eql(u8, basename, dotnet.dll_name_il2cpp)) return .il2cpp;
    return null;
}

pub fn load(
    comptime Funcs: type,
    name: [*:0]const u8,
    kind: dotnet.Kind,
    dll: [:0]u8,
    options: Options,
) error{Reported}!Host(Funcs) {
    switch (kind) {
        .mono => if (options.data_dir != null) return fail("a data dir does not apply to mono", .{}),
        .il2cpp => if (options.assembly_path != null) return fail("an assembly path does not apply to il2cpp", .{}),
    }
    var loaded: Loaded = .directly;
    const module = dynlib.load(dll) catch |err| switch (err) {
        error.NotFound => blk: {
            // The DLL or one of its dependencies wasn't found. A game's runtime DLL
            // sits next to its dependencies, so retry with that dir on the search path.
            dynlib.setDllDirectoryOf(dll) catch |dir_err| switch (dir_err) {
                error.NotFound => return fail("'{s}' has no directory to search for its dependencies", .{dll}),
                error.Unexpected => return error.Reported,
            };
            loaded = .after_set_dll_directory;
            break :blk dynlib.load(dll) catch |retry_err| switch (retry_err) {
                error.NotFound => return fail("'{s}' or one of its dependencies was not found", .{dll}),
                error.Unexpected => return error.Reported,
            };
        },
        error.Unexpected => return error.Reported,
    };
    var missing_proc: [:0]const u8 = undefined;
    const funcs = dotnetload.resolve(Funcs, kind, module, &missing_proc) catch return fail(
        "'{s}' is missing proc '{s}'",
        .{ dll, missing_proc },
    );
    const domain: *const dotnet.Domain = switch (funcs.kind) {
        .mono => |*mono| blk: {
            if (options.assembly_path) |path| mono.set_assemblies_path(path);
            break :blk mono.jit_init(name) orelse return fail("mono_jit_init failed", .{});
        },
        .il2cpp => |*il2cpp| blk: {
            if (options.data_dir) |dir| il2cpp.set_data_dir(dir);
            il2cpp.init(name);
            break :blk funcs.get_root_domain() orelse return fail("il2cpp_init gave no root domain", .{});
        },
    };
    return .{ .module = module, .loaded = loaded, .funcs = funcs, .domain = domain };
}

fn fail(comptime fmt: []const u8, args: anytype) error{Reported} {
    std.log.err(fmt, args);
    return error.Reported;
}

const std = @import("std");
const dotnet = @import("dotnet.zig");
const dotnetload = @import("dotnetload.zig");
const dynlib = @import("dynlib.zig");
