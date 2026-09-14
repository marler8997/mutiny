pub const Opcode = enum(u16) {
    nop = 0x00,
    @"break" = 0x01,
    @"ldarg.0" = 0x02,
    @"ldarg.1" = 0x03,
    @"ldarg.2" = 0x04,
    @"ldarg.3" = 0x05,
    @"ldloc.0" = 0x06,
    @"ldloc.1" = 0x07,
    @"ldloc.2" = 0x08,
    @"ldloc.3" = 0x09,
    @"stloc.0" = 0x0A,
    @"stloc.1" = 0x0B,
    @"stloc.2" = 0x0C,
    @"stloc.3" = 0x0D,
    @"ldarg.s" = 0x0E,
    @"ldarga.s" = 0x0F,
    @"starg.s" = 0x10,
    @"ldloc.s" = 0x11,
    @"ldloca.s" = 0x12,
    @"stloc.s" = 0x13,
    ldnull = 0x14,
    @"ldc.i4.m1" = 0x15,
    @"ldc.i4.0" = 0x16,
    @"ldc.i4.1" = 0x17,
    @"ldc.i4.2" = 0x18,
    @"ldc.i4.3" = 0x19,
    @"ldc.i4.4" = 0x1A,
    @"ldc.i4.5" = 0x1B,
    @"ldc.i4.6" = 0x1C,
    @"ldc.i4.7" = 0x1D,
    @"ldc.i4.8" = 0x1E,
    @"ldc.i4.s" = 0x1F,
    @"ldc.i4" = 0x20,
    @"ldc.i8" = 0x21,
    @"ldc.r4" = 0x22,
    @"ldc.r8" = 0x23,
    dup = 0x25,
    pop = 0x26,
    jmp = 0x27,
    call = 0x28,
    calli = 0x29,
    ret = 0x2A,
    @"br.s" = 0x2B,
    @"brfalse.s" = 0x2C,
    @"brtrue.s" = 0x2D,
    @"beq.s" = 0x2E,
    @"bge.s" = 0x2F,
    @"bgt.s" = 0x30,
    @"ble.s" = 0x31,
    @"blt.s" = 0x32,
    @"bne.un.s" = 0x33,
    @"bge.un.s" = 0x34,
    @"bgt.un.s" = 0x35,
    @"ble.un.s" = 0x36,
    @"blt.un.s" = 0x37,
    br = 0x38,
    brfalse = 0x39,
    brtrue = 0x3A,
    beq = 0x3B,
    bge = 0x3C,
    bgt = 0x3D,
    ble = 0x3E,
    blt = 0x3F,
    @"bne.un" = 0x40,
    @"bge.un" = 0x41,
    @"bgt.un" = 0x42,
    @"ble.un" = 0x43,
    @"blt.un" = 0x44,
    @"switch" = 0x45,
    @"ldind.i1" = 0x46,
    @"ldind.u1" = 0x47,
    @"ldind.i2" = 0x48,
    @"ldind.u2" = 0x49,
    @"ldind.i4" = 0x4A,
    @"ldind.u4" = 0x4B,
    @"ldind.i8" = 0x4C,
    @"ldind.i" = 0x4D,
    @"ldind.r4" = 0x4E,
    @"ldind.r8" = 0x4F,
    @"ldind.ref" = 0x50,
    @"stind.ref" = 0x51,
    @"stind.i1" = 0x52,
    @"stind.i2" = 0x53,
    @"stind.i4" = 0x54,
    @"stind.i8" = 0x55,
    @"stind.r4" = 0x56,
    @"stind.r8" = 0x57,
    add = 0x58,
    sub = 0x59,
    mul = 0x5A,
    div = 0x5B,
    @"div.un" = 0x5C,
    rem = 0x5D,
    @"rem.un" = 0x5E,
    @"and" = 0x5F,
    @"or" = 0x60,
    xor = 0x61,
    shl = 0x62,
    shr = 0x63,
    @"shr.un" = 0x64,
    neg = 0x65,
    not = 0x66,
    @"conv.i1" = 0x67,
    @"conv.i2" = 0x68,
    @"conv.i4" = 0x69,
    @"conv.i8" = 0x6A,
    @"conv.r4" = 0x6B,
    @"conv.r8" = 0x6C,
    @"conv.u4" = 0x6D,
    @"conv.u8" = 0x6E,
    callvirt = 0x6F,
    cpobj = 0x70,
    ldobj = 0x71,
    ldstr = 0x72,
    newobj = 0x73,
    castclass = 0x74,
    isinst = 0x75,
    @"conv.r.un" = 0x76,
    unbox = 0x79,
    throw = 0x7A,
    ldfld = 0x7B,
    ldflda = 0x7C,
    stfld = 0x7D,
    ldsfld = 0x7E,
    ldsflda = 0x7F,
    stsfld = 0x80,
    stobj = 0x81,
    @"conv.ovf.i1.un" = 0x82,
    @"conv.ovf.i2.un" = 0x83,
    @"conv.ovf.i4.un" = 0x84,
    @"conv.ovf.i8.un" = 0x85,
    @"conv.ovf.u1.un" = 0x86,
    @"conv.ovf.u2.un" = 0x87,
    @"conv.ovf.u4.un" = 0x88,
    @"conv.ovf.u8.un" = 0x89,
    @"conv.ovf.i.un" = 0x8A,
    @"conv.ovf.u.un" = 0x8B,
    box = 0x8C,
    newarr = 0x8D,
    ldlen = 0x8E,
    ldelema = 0x8F,
    @"ldelem.i1" = 0x90,
    @"ldelem.u1" = 0x91,
    @"ldelem.i2" = 0x92,
    @"ldelem.u2" = 0x93,
    @"ldelem.i4" = 0x94,
    @"ldelem.u4" = 0x95,
    @"ldelem.i8" = 0x96,
    @"ldelem.i" = 0x97,
    @"ldelem.r4" = 0x98,
    @"ldelem.r8" = 0x99,
    @"ldelem.ref" = 0x9A,
    @"stelem.i" = 0x9B,
    @"stelem.i1" = 0x9C,
    @"stelem.i2" = 0x9D,
    @"stelem.i4" = 0x9E,
    @"stelem.i8" = 0x9F,
    @"stelem.r4" = 0xA0,
    @"stelem.r8" = 0xA1,
    @"stelem.ref" = 0xA2,
    ldelem = 0xA3,
    stelem = 0xA4,
    @"unbox.any" = 0xA5,
    @"conv.ovf.i1" = 0xB3,
    @"conv.ovf.u1" = 0xB4,
    @"conv.ovf.i2" = 0xB5,
    @"conv.ovf.u2" = 0xB6,
    @"conv.ovf.i4" = 0xB7,
    @"conv.ovf.u4" = 0xB8,
    @"conv.ovf.i8" = 0xB9,
    @"conv.ovf.u8" = 0xBA,
    refanyval = 0xC2,
    ckfinite = 0xC3,
    mkrefany = 0xC6,
    ldtoken = 0xD0,
    @"conv.u2" = 0xD1,
    @"conv.u1" = 0xD2,
    @"conv.i" = 0xD3,
    @"conv.ovf.i" = 0xD4,
    @"conv.ovf.u" = 0xD5,
    @"add.ovf" = 0xD6,
    @"add.ovf.un" = 0xD7,
    @"mul.ovf" = 0xD8,
    @"mul.ovf.un" = 0xD9,
    @"sub.ovf" = 0xDA,
    @"sub.ovf.un" = 0xDB,
    endfinally = 0xDC,
    leave = 0xDD,
    @"leave.s" = 0xDE,
    @"stind.i" = 0xDF,
    @"conv.u" = 0xE0,

    arglist = 0xFE00,
    ceq = 0xFE01,
    cgt = 0xFE02,
    @"cgt.un" = 0xFE03,
    clt = 0xFE04,
    @"clt.un" = 0xFE05,
    ldftn = 0xFE06,
    ldvirtftn = 0xFE07,
    ldarg = 0xFE09,
    ldarga = 0xFE0A,
    starg = 0xFE0B,
    ldloc = 0xFE0C,
    ldloca = 0xFE0D,
    stloc = 0xFE0E,
    localloc = 0xFE0F,
    endfilter = 0xFE11,
    @"unaligned." = 0xFE12,
    @"volatile." = 0xFE13,
    @"tail." = 0xFE14,
    initobj = 0xFE15,
    @"constrained." = 0xFE16,
    cpblk = 0xFE17,
    initblk = 0xFE18,
    @"no." = 0xFE19,
    rethrow = 0xFE1A,
    sizeof = 0xFE1C,
    refanytype = 0xFE1D,
    @"readonly." = 0xFE1E,

    pub const two_byte_prefix = 0xFE;

    pub fn name(opcode: Opcode) [:0]const u8 {
        return @tagName(opcode);
    }

    pub fn operandKind(opcode: Opcode) OperandKind {
        return switch (opcode) {
            .@"ldc.i4.s" => .int8,
            .@"ldc.i4" => .int32,
            .@"ldc.i8" => .int64,
            .@"ldc.r4" => .float32,
            .@"ldc.r8" => .float64,
            .@"ldarg.s", .@"ldarga.s", .@"starg.s" => .arg8,
            .ldarg, .ldarga, .starg => .arg16,
            .@"ldloc.s", .@"ldloca.s", .@"stloc.s" => .local8,
            .ldloc, .ldloca, .stloc => .local16,
            .@"unaligned.", .@"no." => .uint8,
            .@"br.s",
            .@"brfalse.s",
            .@"brtrue.s",
            .@"beq.s",
            .@"bge.s",
            .@"bgt.s",
            .@"ble.s",
            .@"blt.s",
            .@"bne.un.s",
            .@"bge.un.s",
            .@"bgt.un.s",
            .@"ble.un.s",
            .@"blt.un.s",
            .@"leave.s",
            => .branch8,
            .br,
            .brfalse,
            .brtrue,
            .beq,
            .bge,
            .bgt,
            .ble,
            .blt,
            .@"bne.un",
            .@"bge.un",
            .@"bgt.un",
            .@"ble.un",
            .@"blt.un",
            .leave,
            => .branch32,
            .@"switch" => .switch_table,
            .jmp, .call, .callvirt, .newobj, .ldftn, .ldvirtftn => .method,
            .ldfld, .ldflda, .stfld, .ldsfld, .ldsflda, .stsfld => .field,
            .cpobj,
            .ldobj,
            .castclass,
            .isinst,
            .unbox,
            .stobj,
            .box,
            .newarr,
            .ldelema,
            .ldelem,
            .stelem,
            .@"unbox.any",
            .refanyval,
            .mkrefany,
            .initobj,
            .@"constrained.",
            .sizeof,
            => .type,
            .ldstr => .string,
            .calli => .signature,
            .ldtoken => .token,
            else => .none,
        };
    }
};

pub const OperandKind = enum {
    none,
    int8,
    int32,
    int64,
    float32,
    float64,
    arg8,
    arg16,
    local8,
    local16,
    uint8,
    branch8,
    branch32,
    switch_table,
    method,
    field,
    type,
    string,
    signature,
    token,
};

pub const Operand = union(enum) {
    none,
    int: i64,
    float32: f32,
    float64: f64,
    arg: u16,
    local: u16,
    uint8: u8,
    branch: usize,
    @"switch": Switch,
    method: u32,
    field: u32,
    type: u32,
    string: u32,
    signature: u32,
    token: u32,
};

pub const Switch = struct {
    base: usize,
    table: []const u8,

    pub fn count(s: Switch) usize {
        return s.table.len / 4;
    }

    pub fn target(s: Switch, index: usize) usize {
        const delta = std.mem.readInt(i32, s.table[index * 4 ..][0..4], .little);
        return @intCast(@as(i64, @intCast(s.base)) + delta);
    }
};

pub const Instruction = struct {
    offset: usize,
    end: usize,
    opcode: Opcode,
    operand: Operand,
};

pub const Error = error{
    Truncated,
    UnknownOpcode,
    BranchOutOfRange,
};

pub const Decoder = struct {
    code: []const u8,
    offset: usize = 0,

    pub fn init(code: []const u8) Decoder {
        return .{ .code = code };
    }

    pub fn next(d: *Decoder) Error!?Instruction {
        if (d.offset == d.code.len) return null;
        var r: Reader = .{ .code = d.code, .pos = d.offset };
        const first = try r.int(u8);
        const value: u16 = if (first == Opcode.two_byte_prefix)
            @as(u16, Opcode.two_byte_prefix) << 8 | try r.int(u8)
        else
            first;
        const opcode = std.enums.fromInt(Opcode, value) orelse return error.UnknownOpcode;
        const operand: Operand = switch (opcode.operandKind()) {
            .none => .none,
            .int8 => .{ .int = try r.int(i8) },
            .int32 => .{ .int = try r.int(i32) },
            .int64 => .{ .int = try r.int(i64) },
            .float32 => .{ .float32 = @bitCast(try r.int(u32)) },
            .float64 => .{ .float64 = @bitCast(try r.int(u64)) },
            .arg8 => .{ .arg = try r.int(u8) },
            .arg16 => .{ .arg = try r.int(u16) },
            .local8 => .{ .local = try r.int(u8) },
            .local16 => .{ .local = try r.int(u16) },
            .uint8 => .{ .uint8 = try r.int(u8) },
            .branch8 => .{ .branch = try r.branchTarget(try r.int(i8)) },
            .branch32 => .{ .branch = try r.branchTarget(try r.int(i32)) },
            .switch_table => .{ .@"switch" = try r.switchTable() },
            .method => .{ .method = try r.int(u32) },
            .field => .{ .field = try r.int(u32) },
            .type => .{ .type = try r.int(u32) },
            .string => .{ .string = try r.int(u32) },
            .signature => .{ .signature = try r.int(u32) },
            .token => .{ .token = try r.int(u32) },
        };
        const instruction: Instruction = .{ .offset = d.offset, .end = r.pos, .opcode = opcode, .operand = operand };
        d.offset = r.pos;
        return instruction;
    }
};

const Reader = struct {
    code: []const u8,
    pos: usize,

    fn bytes(r: *Reader, len: u64) Error![]const u8 {
        if (r.code.len - r.pos < len) return error.Truncated;
        const slice = r.code[r.pos..][0..@intCast(len)];
        r.pos += slice.len;
        return slice;
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const slice = try r.bytes(@sizeOf(T));
        return std.mem.readInt(T, slice[0..@sizeOf(T)], .little);
    }

    fn branchTarget(r: *const Reader, delta: i32) Error!usize {
        return targetFrom(r.code.len, r.pos, delta);
    }

    fn switchTable(r: *Reader) Error!Switch {
        const count = try r.int(u32);
        const table = try r.bytes(@as(u64, count) * 4);
        const s: Switch = .{ .base = r.pos, .table = table };
        for (0..count) |i| {
            _ = try targetFrom(r.code.len, s.base, std.mem.readInt(i32, table[i * 4 ..][0..4], .little));
        }
        return s;
    }
};

fn targetFrom(code_len: usize, base: usize, delta: i32) Error!usize {
    const target = @as(i64, @intCast(base)) + delta;
    if (target < 0 or target >= code_len) return error.BranchOutOfRange;
    return @intCast(target);
}

fn expectDecodes(code: []const u8, expected: []const struct { Opcode, Operand }) !void {
    var d: Decoder = .init(code);
    for (expected) |e| {
        const instruction = (try d.next()) orelse return error.TestUnexpectedEnd;
        try std.testing.expectEqual(e[0], instruction.opcode);
        try std.testing.expectEqualDeep(e[1], instruction.operand);
    }
    try std.testing.expectEqual(null, try d.next());
}

fn expectError(expected: Error, code: []const u8) !void {
    var d: Decoder = .init(code);
    while (d.next()) |maybe| {
        if (maybe == null) return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(expected, err);
}

test "a method body with no operands" {
    try expectDecodes(&.{ 0x02, 0x03, 0x58, 0x2A }, &.{
        .{ .@"ldarg.0", .none },
        .{ .@"ldarg.1", .none },
        .{ .add, .none },
        .{ .ret, .none },
    });
}

test "constant operands are little endian and sign extended" {
    try expectDecodes(&.{
        0x1F, 0xFF,
        0x20, 0x78, 0x56, 0x34, 0x12,
        0x21, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
        0x22, 0x00, 0x00, 0xC0, 0x3F,
        0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xC0,
    }, &.{
        .{ .@"ldc.i4.s", .{ .int = -1 } },
        .{ .@"ldc.i4", .{ .int = 0x12345678 } },
        .{ .@"ldc.i8", .{ .int = std.math.maxInt(i64) } },
        .{ .@"ldc.r4", .{ .float32 = 1.5 } },
        .{ .@"ldc.r8", .{ .float64 = -2.5 } },
    });
}

test "argument, local and prefix operands" {
    try expectDecodes(&.{
        0x0E, 0x05,
        0xFE, 0x0C, 0x2C, 0x01,
        0x13, 0xFF,
        0xFE, 0x0B, 0x01, 0x00,
        0xFE, 0x12, 0x04,
        0xFE, 0x14,
    }, &.{
        .{ .@"ldarg.s", .{ .arg = 5 } },
        .{ .ldloc, .{ .local = 300 } },
        .{ .@"stloc.s", .{ .local = 255 } },
        .{ .starg, .{ .arg = 1 } },
        .{ .@"unaligned.", .{ .uint8 = 4 } },
        .{ .@"tail.", .none },
    });
}

test "metadata token operands keep their kind" {
    try expectDecodes(&.{
        0x28, 0x01, 0x00, 0x00, 0x0A,
        0x7D, 0x02, 0x00, 0x00, 0x04,
        0x8C, 0x03, 0x00, 0x00, 0x02,
        0x72, 0x04, 0x00, 0x00, 0x70,
        0x29, 0x05, 0x00, 0x00, 0x11,
        0xD0, 0x06, 0x00, 0x00, 0x01,
        0xFE, 0x16, 0x07, 0x00, 0x00, 0x1B,
        0xFE, 0x06, 0x08, 0x00, 0x00, 0x2B,
    }, &.{
        .{ .call, .{ .method = 0x0A000001 } },
        .{ .stfld, .{ .field = 0x04000002 } },
        .{ .box, .{ .type = 0x02000003 } },
        .{ .ldstr, .{ .string = 0x70000004 } },
        .{ .calli, .{ .signature = 0x11000005 } },
        .{ .ldtoken, .{ .token = 0x01000006 } },
        .{ .@"constrained.", .{ .type = 0x1B000007 } },
        .{ .ldftn, .{ .method = 0x2B000008 } },
    });
}

test "branch targets are absolute and relative to the next instruction" {
    try expectDecodes(&.{
        0x2B, 0x05,
        0x38, 0xFB, 0xFF, 0xFF, 0xFF,
        0x00,
        0xDE, 0xF8,
        0x2A,
    }, &.{
        .{ .@"br.s", .{ .branch = 7 } },
        .{ .br, .{ .branch = 2 } },
        .{ .nop, .none },
        .{ .@"leave.s", .{ .branch = 2 } },
        .{ .ret, .none },
    });
}

test "switch targets are relative to the end of the table" {
    const code = [_]u8{
        0x45, 0x02, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x2A,
        0x2A,
    };
    var d: Decoder = .init(&code);
    const instruction = (try d.next()).?;
    try std.testing.expectEqual(Opcode.@"switch", instruction.opcode);
    try std.testing.expectEqual(13, instruction.end);
    const s = instruction.operand.@"switch";
    try std.testing.expectEqual(2, s.count());
    try std.testing.expectEqual(13, s.target(0));
    try std.testing.expectEqual(14, s.target(1));
    try std.testing.expectEqual(Opcode.ret, (try d.next()).?.opcode);
    try std.testing.expectEqual(Opcode.ret, (try d.next()).?.opcode);
    try std.testing.expectEqual(null, try d.next());
}

test "an empty switch is valid" {
    try expectDecodes(&.{ 0x45, 0x00, 0x00, 0x00, 0x00, 0x2A }, &.{
        .{ .@"switch", .{ .@"switch" = .{ .base = 5, .table = &.{} } } },
        .{ .ret, .none },
    });
}

test "truncated instructions are errors" {
    try expectError(error.Truncated, &.{0xFE});
    try expectError(error.Truncated, &.{ 0x20, 0x00, 0x00 });
    try expectError(error.Truncated, &.{ 0x28, 0x01 });
    try expectError(error.Truncated, &.{ 0x2A, 0x2B });
    try expectError(error.Truncated, &.{ 0x45, 0x01, 0x00, 0x00 });
    try expectError(error.Truncated, &.{ 0x45, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00 });
}

test "opcodes ECMA-335 leaves unassigned are errors" {
    try expectError(error.UnknownOpcode, &.{0x24});
    try expectError(error.UnknownOpcode, &.{0xA6});
    try expectError(error.UnknownOpcode, &.{0xE1});
    try expectError(error.UnknownOpcode, &.{0xF0});
    try expectError(error.UnknownOpcode, &.{ 0xFE, 0x08 });
    try expectError(error.UnknownOpcode, &.{ 0xFE, 0x1F });
}

test "branches outside the method are errors" {
    try expectError(error.BranchOutOfRange, &.{ 0x2B, 0xFD });
    try expectError(error.BranchOutOfRange, &.{ 0x2B, 0x00 });
    try expectError(error.BranchOutOfRange, &.{ 0x38, 0x01, 0x00, 0x00, 0x00, 0x2A });
    try expectError(error.BranchOutOfRange, &.{ 0x45, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x2A });
}

test "every opcode decodes to itself with an operand of its declared size" {
    for (std.enums.values(Opcode)) |opcode| {
        var buf: [16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const value = @intFromEnum(opcode);
        if (value > 0xFF) try w.writeByte(Opcode.two_byte_prefix);
        try w.writeByte(@truncate(value));
        const operand_len: usize = switch (opcode.operandKind()) {
            .none => 0,
            .int8, .arg8, .local8, .uint8, .branch8 => 1,
            .arg16, .local16 => 2,
            .int32, .float32, .branch32, .switch_table, .method, .field, .type, .string, .signature, .token => 4,
            .int64, .float64 => 8,
        };
        try w.splatByteAll(0, operand_len);
        const len = w.end;
        try w.writeByte(@intFromEnum(Opcode.nop));

        var d: Decoder = .init(w.buffered());
        const instruction = (try d.next()).?;
        try std.testing.expectEqual(opcode, instruction.opcode);
        try std.testing.expectEqual(len, instruction.end);
        try std.testing.expectEqual(Opcode.nop, (try d.next()).?.opcode);
        try std.testing.expectEqual(null, try d.next());
    }
}

const std = @import("std");
