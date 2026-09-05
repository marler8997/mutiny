const AssemblyFormat = enum { names, decomp };

pub fn writeDecomp(
    dotnet_funcs: *const dotnet.Funcs,
    writer: *std.Io.Writer,
) error{WriteFailed}!void {
    try writer.print("runtime\t{s}\n", .{@tagName(dotnet_funcs.kind)});

    var path_buf: [appdata.max_path:0]u16 = undefined;
    {
        const len = win32.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0) win32.panicWin32("GetModuleFileNameW(null)", win32.GetLastError());
        try writer.print("exe\t{f}\n", .{fmtW(path_buf[0..len])});
    }
    switch (dotnet_funcs.kind) {
        .mono => {},
        .il2cpp => {
            const module = win32.GetModuleHandleW(
                win32.L(dotnet.dll_name_il2cpp),
            ) orelse win32.panicWin32("GetModuleHandleW", win32.GetLastError());
            const len = win32.GetModuleFileNameW(module, &path_buf, path_buf.len);
            if (len == 0) win32.panicWin32("GetModuleFileNameW", win32.GetLastError());
            try writer.print("module\t{s}\t{f}\n", .{
                dotnet.dll_name_il2cpp,
                fmtW(path_buf[0..len]),
            });
        },
    }
    try writeAssemblies(dotnet_funcs, writer, .decomp);
}

const WriteAssemblies = struct {
    dotnet_funcs: *const dotnet.Funcs,
    writer: *std.Io.Writer,
    format: AssemblyFormat,
    index: usize = 0,
    write_failed: bool = false,
};

fn writeAssembliesMono(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *const dotnet.Assembly = @ptrCast(assembly_opaque);
    const ctx: *WriteAssemblies = @ptrCast(@alignCast(user_data));
    defer ctx.index += 1;
    const mono = &ctx.dotnet_funcs.kind.mono;
    const assembly_name = mono.assembly_get_name(assembly) orelse {
        std.log.err("  assembly[{}] mono_assembly_get_name failed", .{ctx.index});
        return;
    };
    const str = mono.assembly_name_get_name(assembly_name) orelse {
        std.log.err(
            "  assembly[{}] mono_assembly_name_get_name failed (assembly_ptr=0x{x}, name_ptr=0x{x})",
            .{ ctx.index, @intFromPtr(assembly), @intFromPtr(assembly_name) },
        );
        return;
    };
    const name = std.mem.span(str);
    const result = switch (ctx.format) {
        .names => ctx.writer.print("{s}\n", .{name}),
        .decomp => blk: {
            const image = ctx.dotnet_funcs.assembly_get_image(assembly) orelse {
                std.log.err("  assembly[{}] mono_assembly_get_image failed", .{ctx.index});
                return;
            };
            const filename = mono.image_get_filename(image) orelse {
                std.log.err("  assembly[{}] mono_image_get_filename failed", .{ctx.index});
                return;
            };
            break :blk ctx.writer.print("assembly\t{s}\t{s}\n", .{ name, std.mem.span(filename) });
        },
    };
    result catch |err| switch (err) {
        error.WriteFailed => ctx.write_failed = true,
    };
}

pub fn writeAssemblies(
    dotnet_funcs: *const dotnet.Funcs,
    writer: *std.Io.Writer,
    format: AssemblyFormat,
) error{WriteFailed}!void {
    switch (dotnet_funcs.kind) {
        .mono => |*mono| {
            var context: WriteAssemblies = .{
                .dotnet_funcs = dotnet_funcs,
                .writer = writer,
                .format = format,
            };
            mono.assembly_foreach(&writeAssembliesMono, &context);
            if (context.write_failed) return error.WriteFailed;
        },
        .il2cpp => |*il2cpp| {
            var assembly_count: usize = undefined;
            const assemblies = il2cpp.domain_get_assemblies(
                dotnet_funcs.domain_get().?,
                &assembly_count,
            );
            for (0..assembly_count) |i| {
                const image = il2cpp.assembly_get_image(assemblies[i]);
                const image_name = std.mem.span(il2cpp.image_get_name(image));
                if (std.mem.eql(u8, image_name, "__Generated")) continue;
                if (!std.mem.endsWith(u8, image_name, ".dll")) std.debug.panic(
                    "expected all image names to end with '.dll' but got '{s}'",
                    .{image_name},
                );
                const name = image_name[0 .. image_name.len - ".dll".len];
                switch (format) {
                    .names => try writer.print("{s}\n", .{name}),
                    .decomp => try writer.print("assembly\t{s}\n", .{name}),
                }
            }
        },
    }
}

const fmtW = std.unicode.fmtUtf16Le;

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");

const appdata = mutiny.appdata;
const dotnet = mutiny.dotnet;
