pub const max_instruction = c.ZYDIS_MAX_INSTRUCTION_LENGTH;
pub const max_operand_count = c.ZYDIS_MAX_OPERAND_COUNT;

pub const DecodedInstruction = c.ZydisDecodedInstruction;
pub const DecodedOperand = c.ZydisDecodedOperand;
pub const mnemonic_call = c.ZYDIS_MNEMONIC_CALL;
pub const mnemonic_jmp = c.ZYDIS_MNEMONIC_JMP;
pub const mnemonic_ret = c.ZYDIS_MNEMONIC_RET;

pub fn relativeBranchTarget(instr: *const DecodedInstruction, operands: *const [max_operand_count]DecodedOperand, addr: usize) ?usize {
    if (instr.operand_count_visible == 0) return null;
    const op = &operands[0];
    if (op.type != c.ZYDIS_OPERAND_TYPE_IMMEDIATE) return null;
    const imm = &op.unnamed_0.imm;
    if (imm.is_relative == 0) return null;
    const next: isize = @intCast(addr + instr.length);
    return @bitCast(next +% imm.value.s);
}

/// Whether control never reaches the next instruction: past this is not this function's code.
pub fn endsCode(instr: *const DecodedInstruction) bool {
    return instr.mnemonic == c.ZYDIS_MNEMONIC_RET or
        instr.mnemonic == c.ZYDIS_MNEMONIC_INT3 or
        instr.mnemonic == c.ZYDIS_MNEMONIC_UD2 or
        instr.mnemonic == c.ZYDIS_MNEMONIC_HLT or
        instr.mnemonic == c.ZYDIS_MNEMONIC_JMP;
}

/// Whether an instruction is a call or a divide, or touches memory other than the stack or
/// rip-relative data. This includes implicit operands, like the [rdi] of stos.
pub fn mayFaultOrCall(instr: *const DecodedInstruction, operands: *const [max_operand_count]DecodedOperand) bool {
    switch (instr.mnemonic) {
        c.ZYDIS_MNEMONIC_CALL, c.ZYDIS_MNEMONIC_DIV, c.ZYDIS_MNEMONIC_IDIV => return true,
        else => {},
    }
    for (operands[0..instr.operand_count]) |*operand| {
        if (operand.type != c.ZYDIS_OPERAND_TYPE_MEMORY) continue;
        const mem = &operand.unnamed_0.mem;
        if (mem.type == c.ZYDIS_MEMOP_TYPE_AGEN) continue; // lea only computes the address
        if (mem.index != c.ZYDIS_REGISTER_NONE) return true;
        if (mem.segment == c.ZYDIS_REGISTER_FS or mem.segment == c.ZYDIS_REGISTER_GS) return true;
        switch (mem.base) {
            c.ZYDIS_REGISTER_RSP, c.ZYDIS_REGISTER_RBP, c.ZYDIS_REGISTER_RIP => {},
            else => return true,
        }
    }
    return false;
}

pub fn instructionLength(status: *Status, code: [*]const u8) error{Error}!usize {
    return (try decodeInstruction(status, code)).length;
}

pub fn decodeInstruction(status: *Status, code: [*]const u8) error{Error}!DecodedInstruction {
    var instr: DecodedInstruction = undefined;
    try status.check(c.ZydisDecoderDecodeInstruction(&decoder, null, code, max_instruction, &instr));
    return instr;
}

pub const Status = packed struct(u32) {
    code: u20,
    module: u11,
    failed: bool,
    pub fn check(self: *Status, status_c: c.ZyanStatus) error{Error}!void {
        const status: Status = @bitCast(status_c);
        if (status.failed) {
            self.* = status;
            return error.Error;
        }
    }
    pub fn format(self: Status, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (self.failed) {
            const mod_name: ?ModuleName = .init(self.module);
            const name_prefix: []const u8, const name_suffix: []const u8 =
                if (mod_name != null) .{ "(", ")" } else .{ "", "" };
            try writer.print("errorcode {d} module {d}{s}{s}{s}", .{
                self.code,
                self.module,
                name_prefix,
                if (mod_name) |n| @tagName(n) else "",
                name_suffix,
            });
        } else {
            try writer.writeAll("success");
        }
    }
};

const ModuleName = enum {
    zycore,
    zydis,
    pub fn init(module: u11) ?ModuleName {
        return switch (module) {
            c.ZYAN_MODULE_ZYCORE => .zycore,
            c.ZYAN_MODULE_ZYDIS => .zydis,
            else => null,
        };
    }
};

pub fn decodeFull(
    status: *Status,
    code: [*]const u8,
    instr: *DecodedInstruction,
    operands: *[max_operand_count]DecodedOperand,
) error{Error}!void {
    try status.check(c.ZydisDecoderDecodeFull(&decoder, code, max_instruction, instr, operands));
}

pub fn reencode(
    status: *Status,
    instr: *const DecodedInstruction,
    operands: *const [max_operand_count]DecodedOperand,
    src_addr: usize,
    dst: []u8,
    dst_addr: u64,
) error{Error}!usize {
    var request: c.ZydisEncoderRequest = undefined;
    try status.check(c.ZydisEncoderDecodedInstructionToEncoderRequest(
        instr,
        operands,
        instr.operand_count_visible,
        &request,
    ));

    // ToEncoderRequest copies operands 1:1 into request.operands, keeping their source-relative
    // disp/imm; EncodeInstructionAbsolute wants absolute targets, so overwrite each relative operand
    // with its absolute address (computed from where the instruction currently lives).
    for (
        operands[0..instr.operand_count_visible],
        request.operands[0..instr.operand_count_visible],
    ) |*decoded, *encoded| {
        const relative = switch (decoded.type) {
            c.ZYDIS_OPERAND_TYPE_IMMEDIATE => decoded.unnamed_0.imm.is_relative != 0,
            c.ZYDIS_OPERAND_TYPE_MEMORY => decoded.unnamed_0.mem.base == c.ZYDIS_REGISTER_RIP,
            else => false,
        };
        if (!relative) continue;

        var abs: u64 = undefined;
        try status.check(c.ZydisCalcAbsoluteAddress(instr, decoded, src_addr, &abs));
        switch (decoded.type) {
            c.ZYDIS_OPERAND_TYPE_IMMEDIATE => encoded.imm.u = abs,
            c.ZYDIS_OPERAND_TYPE_MEMORY => encoded.mem.displacement = @bitCast(abs),
            else => unreachable,
        }
    }

    var len: usize = dst.len;
    try status.check(c.ZydisEncoderEncodeInstructionAbsolute(&request, dst.ptr, &len, dst_addr));
    return len;
}

// detour.zig relies on these: a far trampoline is only safe because an instruction that can't
// reach its target from there fails to re-encode, rather than encoding a truncated offset.
const reencode_tests = struct {
    const src_addr: usize = 0x1000_0000_0000;
    const near = 0x1000;
    const far = 0x1_0000_0000; // 4GB, out of range of a signed 32-bit offset

    const Decoded = struct {
        instr: DecodedInstruction,
        operands: [max_operand_count]DecodedOperand,
    };

    fn decode(code: []const u8) !Decoded {
        var padded = [_]u8{0x90} ** max_instruction;
        @memcpy(padded[0..code.len], code);
        var status: Status = undefined;
        var decoded: Decoded = undefined;
        try decodeFull(&status, &padded, &decoded.instr, &decoded.operands);
        return decoded;
    }

    /// The absolute address an instruction's relative operand refers to, or null if it has none.
    fn absoluteTarget(decoded: *const Decoded, addr: u64) !?u64 {
        for (decoded.operands[0..decoded.instr.operand_count_visible]) |*operand| {
            const relative = switch (operand.type) {
                c.ZYDIS_OPERAND_TYPE_IMMEDIATE => operand.unnamed_0.imm.is_relative != 0,
                c.ZYDIS_OPERAND_TYPE_MEMORY => operand.unnamed_0.mem.base == c.ZYDIS_REGISTER_RIP,
                else => false,
            };
            if (!relative) continue;
            var target: u64 = undefined;
            var status: Status = undefined;
            try status.check(c.ZydisCalcAbsoluteAddress(&decoded.instr, operand, addr, &target));
            return target;
        }
        return null;
    }

    fn encodeAt(code: []const u8, dst_addr: u64, dst: []u8) !usize {
        const decoded = try decode(code);
        var status: Status = undefined;
        return reencode(&status, &decoded.instr, &decoded.operands, src_addr, dst, dst_addr);
    }

    /// An instruction with a 32-bit reach: moving it nearby keeps its target, and moving it out of
    /// range in either direction is an error.
    fn expectReach(code: []const u8) !void {
        const want = (try absoluteTarget(&(try decode(code)), src_addr)).?;

        var dst: [max_instruction]u8 = undefined;
        const near_addr = src_addr + near;
        const len = try encodeAt(code, near_addr, &dst);
        const moved = try decode(dst[0..len]);
        try std.testing.expectEqual(want, (try absoluteTarget(&moved, near_addr)).?);

        try std.testing.expectError(error.Error, encodeAt(code, src_addr + far, &dst));
        try std.testing.expectError(error.Error, encodeAt(code, src_addr - far, &dst));
    }

    test "a RIP-relative operand can't be re-encoded out of range" {
        try expectReach(&.{ 0x48, 0x8d, 0x05, 0x10, 0x00, 0x00, 0x00 }); // lea rax, [rip+0x10]
        try expectReach(&.{ 0x48, 0x8b, 0x05, 0x10, 0x00, 0x00, 0x00 }); // mov rax, [rip+0x10]
    }

    test "a relative branch can't be re-encoded out of range" {
        try expectReach(&.{ 0xe8, 0x10, 0x00, 0x00, 0x00 }); // call rel32
        try expectReach(&.{ 0xe9, 0x10, 0x00, 0x00, 0x00 }); // jmp rel32
        try expectReach(&.{ 0x0f, 0x84, 0x10, 0x00, 0x00, 0x00 }); // je rel32
    }

    test "a short branch can't be re-encoded further than its 8-bit reach" {
        const code = [_][]const u8{
            &.{ 0xeb, 0x10 }, // jmp rel8
            &.{ 0x74, 0x10 }, // je rel8
        };
        for (code) |bytes| {
            var dst: [max_instruction]u8 = undefined;
            try std.testing.expectError(error.Error, encodeAt(bytes, src_addr + near, &dst));
        }
    }

    test "an instruction with no relative operand re-encodes anywhere, unchanged" {
        const code = [_][]const u8{
            &.{0x55}, // push rbp
            &.{ 0x48, 0x89, 0xe5 }, // mov rbp, rsp
            &.{ 0x48, 0x83, 0xec, 0x20 }, // sub rsp, 0x20
        };
        for (code) |bytes| {
            var dst: [max_instruction]u8 = undefined;
            const len = try encodeAt(bytes, src_addr + far, &dst);
            try std.testing.expectEqualSlices(u8, bytes, dst[0..len]);
        }
    }
};

test {
    _ = reencode_tests;
}

const decoder: c.ZydisDecoder = .{
    .machine_mode = c.ZYDIS_MACHINE_MODE_LONG_64,
    .stack_width = c.ZYDIS_STACK_WIDTH_64,
    .decoder_mode = (1 << c.ZYDIS_DECODER_MODE_MPX) | (1 << c.ZYDIS_DECODER_MODE_CET) |
        (1 << c.ZYDIS_DECODER_MODE_LZCNT) | (1 << c.ZYDIS_DECODER_MODE_TZCNT) |
        (1 << c.ZYDIS_DECODER_MODE_CLDEMOTE) | (1 << c.ZYDIS_DECODER_MODE_IPREFETCH) |
        (1 << c.ZYDIS_DECODER_MODE_APX),
};

const std = @import("std");
const c = @cImport({
    @cInclude("Zydis/Zydis.h");
});
