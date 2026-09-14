pub fn run(funcs: *const Funcs) !void {
    try checkOpcodeTable(funcs);
    try checkCorlibBodies(funcs);
}

fn checkOpcodeTable(funcs: *const Funcs) !void {
    const mono = &funcs.mono;
    var checked: usize = 0;
    for (0..0x100) |byte| {
        if (byte == il.Opcode.two_byte_prefix or byte == mono_custom_prefix) continue;
        try checkOpcodeValue(mono, &.{@intCast(byte)}, @intCast(byte));
        checked += 1;
    }
    for (0..last_two_byte_value + 1) |byte| {
        try checkOpcodeValue(mono, &.{ il.Opcode.two_byte_prefix, @intCast(byte) }, @as(u16, il.Opcode.two_byte_prefix) << 8 | @as(u16, @intCast(byte)));
        checked += 1;
    }
    std.log.info("IL decoder: all {} opcode values match mono's names", .{checked});
}

const mono_custom_prefix = 0xF0;
const last_two_byte_value = 0x1E;

fn checkOpcodeValue(mono: anytype, bytes: []const u8, value: u16) !void {
    var ip: [*]const u8 = bytes.ptr;
    const index = mono.opcode_value(&ip, bytes.ptr + bytes.len);
    if (index < 0) {
        std.log.err("mono_opcode_value found no opcode for 0x{x}", .{value});
        return error.MonoFoundNoOpcode;
    }
    const mono_name = std.mem.span(mono.opcode_name(index));
    if (std.enums.fromInt(il.Opcode, value)) |opcode| {
        if (std.mem.eql(u8, mono_name, opcode.name())) return;
        std.log.err("opcode 0x{x} is '{s}' here but '{s}' in mono", .{ value, opcode.name(), mono_name });
        return error.OpcodeNameMismatch;
    }
    if (std.mem.startsWith(u8, mono_name, "unused") or std.mem.startsWith(u8, mono_name, "prefix")) return;
    std.log.err("opcode 0x{x} is unassigned here but '{s}' in mono", .{ value, mono_name });
    return error.OpcodeMissing;
}

fn checkCorlibBodies(funcs: *const Funcs) !void {
    const mono = &funcs.mono;
    const corlib = mono.get_corlib() orelse return error.NoCorlib;
    const table = mono.image_get_table_info(corlib, dotnet.mono_table_typedef) orelse return error.NoTypedefTable;
    const rows = std.math.cast(u32, mono.table_info_get_rows(table)) orelse return error.NegativeTypedefRowCount;

    var seen: std.EnumSet(il.Opcode) = .initEmpty();
    var methods: usize = 0;
    var instructions: usize = 0;
    for (1..rows + 1) |row| {
        const class = mono.class_get(corlib, dotnet.mono_token_type_def | @as(u32, @intCast(row))) orelse {
            std.log.err("mscorlib typedef row {} did not load", .{row});
            return error.TypedefRowDidNotLoad;
        };
        var iter: ?*anyopaque = null;
        while (funcs.class_get_methods(class, &iter)) |method| {
            const header = mono.method_get_header(method) orelse continue;
            defer mono.metadata_free_mh(header);
            var code_size: u32 = 0;
            var max_stack: u32 = 0;
            const code_ptr = mono.method_header_get_code(header, &code_size, &max_stack) orelse {
                std.log.err("{f}: mono_method_header_get_code returned null", .{fmtMethod(funcs, class, method)});
                return error.NoMethodCode;
            };
            const code = code_ptr[0..code_size];
            methods += 1;

            var decoder: il.Decoder = .init(code);
            while (decoder.next() catch |err| {
                std.log.err("{f}: decoding at IL_{x:0>4} failed with {t}", .{ fmtMethod(funcs, class, method), decoder.offset, err });
                return err;
            }) |instruction| {
                seen.insert(instruction.opcode);
                instructions += 1;
                var ip: [*]const u8 = code_ptr + instruction.offset;
                const value = mono.opcode_value(&ip, code_ptr + code.len);
                if (value < 0) {
                    std.log.err("{f}: mono_opcode_value found no opcode at IL_{x:0>4}", .{ fmtMethod(funcs, class, method), instruction.offset });
                    return error.MonoFoundNoOpcode;
                }
                const mono_name = std.mem.span(mono.opcode_name(value));
                if (!std.mem.eql(u8, mono_name, instruction.opcode.name())) {
                    std.log.err("{f}: IL_{x:0>4} decodes as '{s}' but mono says '{s}'", .{
                        fmtMethod(funcs, class, method),
                        instruction.offset,
                        instruction.opcode.name(),
                        mono_name,
                    });
                    return error.OpcodeNameMismatch;
                }
            }
        }
    }

    var unseen_buf: [4096]u8 = undefined;
    var unseen: std.Io.Writer = .fixed(&unseen_buf);
    var unseen_it = seen.complement().iterator();
    while (unseen_it.next()) |opcode| {
        unseen.print(" {s}", .{opcode.name()}) catch return error.UnseenListTooLong;
    }
    std.log.info("IL decoder: {} instructions in {} mscorlib methods agree with mono's decoder, {} of {} opcodes seen; not seen:{s}", .{
        instructions,
        methods,
        seen.count(),
        std.enums.values(il.Opcode).len,
        unseen.buffered(),
    });
}

const MethodFmt = struct {
    funcs: *const Funcs,
    class: *const dotnet.Class,
    method: *const dotnet.Method,

    pub fn format(f: MethodFmt, w: *std.Io.Writer) error{WriteFailed}!void {
        const namespace = std.mem.span(f.funcs.class_get_namespace(f.class));
        if (namespace.len != 0) try w.print("{s}.", .{namespace});
        try w.print("{s}::{s}", .{ f.funcs.class_get_name(f.class), f.funcs.method_get_name(f.method) });
    }
};

fn fmtMethod(funcs: *const Funcs, class: *const dotnet.Class, method: *const dotnet.Method) MethodFmt {
    return .{ .funcs = funcs, .class = class, .method = method };
}

pub const Funcs = struct {
    class_get_name: *const dotnet.shared.class_get_name,
    class_get_namespace: *const dotnet.shared.class_get_namespace,
    class_get_methods: *const dotnet.shared.class_get_methods,
    method_get_name: *const dotnet.shared.method_get_name,
    mono: struct {
        get_corlib: *const dotnet.mono.get_corlib,
        image_get_table_info: *const dotnet.mono.image_get_table_info,
        table_info_get_rows: *const dotnet.mono.table_info_get_rows,
        class_get: *const dotnet.mono.class_get,
        method_get_header: *const dotnet.mono.method_get_header,
        method_header_get_code: *const dotnet.mono.method_header_get_code,
        metadata_free_mh: *const dotnet.mono.metadata_free_mh,
        opcode_value: *const dotnet.mono.opcode_value,
        opcode_name: *const dotnet.mono.opcode_name,
    },
};

const std = @import("std");
const dotnet = @import("dotnet.zig");
const il = @import("il");
