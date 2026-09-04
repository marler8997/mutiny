pub const max_instruction = c.ZYDIS_MAX_INSTRUCTION_LENGTH;

pub const DecodeError = error{
    TooLong,
    Malformed,
    IllegalLegacyPrefix,
    IllegalLock,
    IllegalRex,
    InvalidMap,
    MalformedEvex,
    MalformedMvex,
    InvalidMask,
    BadRegister,
};

pub fn instructionLength(code: [*]const u8) DecodeError!usize {
    return (try decodeInstruction(code)).length;
}

pub fn decodeInstruction(code: [*]const u8) DecodeError!c.ZydisDecodedInstruction {
    var instr: c.ZydisDecodedInstruction = undefined;
    return switch (c.ZydisDecoderDecodeInstruction(
        &decoder,
        null,
        code,
        max_instruction,
        &instr,
    )) {
        c.ZYAN_STATUS_SUCCESS => instr,
        c.ZYDIS_STATUS_INSTRUCTION_TOO_LONG => error.TooLong,
        c.ZYDIS_STATUS_DECODING_ERROR => error.Malformed,
        c.ZYDIS_STATUS_ILLEGAL_LEGACY_PFX => error.IllegalLegacyPrefix,
        c.ZYDIS_STATUS_ILLEGAL_LOCK => error.IllegalLock,
        c.ZYDIS_STATUS_ILLEGAL_REX => error.IllegalRex,
        c.ZYDIS_STATUS_INVALID_MAP => error.InvalidMap,
        c.ZYDIS_STATUS_MALFORMED_EVEX => error.MalformedEvex,
        c.ZYDIS_STATUS_MALFORMED_MVEX => error.MalformedMvex,
        c.ZYDIS_STATUS_INVALID_MASK => error.InvalidMask,
        c.ZYDIS_STATUS_BAD_REGISTER => error.BadRegister,
        c.ZYDIS_STATUS_NO_MORE_DATA => unreachable, // we passed ZYDIS_MAX_INSTRUCTION_LENGTH
        c.ZYAN_STATUS_INVALID_ARGUMENT => unreachable,
        else => |status| std.debug.panic(
            "zydis: unhandled decode status 0x{x} for 0x{x}",
            .{ status, code[0..max_instruction] },
        ),
    };
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
