pub const max_instruction = c.ZYDIS_MAX_INSTRUCTION_LENGTH;
pub const max_operand_count = c.ZYDIS_MAX_OPERAND_COUNT;

pub const DecodedInstruction = c.ZydisDecodedInstruction;
pub const DecodedOperand = c.ZydisDecodedOperand;

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
