pub const FindError = dynlib.GetProcError || error{
    ExportNotFound,
    NoJumpFound,
    DecodeInstructionFailed,
};

pub fn findFunction(module: dynlib.Module, export_name: [:0]const u8) FindError!usize {
    const proc_addr: usize = @intFromPtr(try dynlib.getProc(module, export_name));
    var next_addr: usize = proc_addr;
    var scanned: usize = 0;
    while (scanned < 32) {
        if (followJump(next_addr)) |target| return target;
        const ptr: [*]const u8 = @ptrFromInt(next_addr);
        const len = zydis.instructionLength(ptr) catch |e| {
            std.log.err(
                "detour: failed to decode instruction 0x{x} at 0x{x} locating '{s}': {t}",
                .{ ptr[0..zydis.max_instruction], next_addr, export_name, e },
            );
            return error.DecodeInstructionFailed;
        };
        next_addr +%= len;
        scanned +%= len;
    }
    return error.NoJumpFound;
}

fn followJump(addr: usize) ?usize {
    const code: [*]const u8 = @ptrFromInt(addr);
    return switch (code[0]) {
        0xe9 => addr +% 5 +% rel(readI32(code + 1)), // jmp rel32
        0xeb => addr +% 2 +% rel(@as(i8, @bitCast(code[1]))), // jmp rel8
        0xff => if (code[1] == 0x25) blk: { // jmp qword [rip+disp32] (import thunk)
            const slot = addr +% 6 +% rel(readI32(code + 2));
            break :blk @as(*align(1) const usize, @ptrFromInt(slot)).*;
        } else null,
        else => null,
    };
}

fn rel(v: anytype) usize {
    return @bitCast(@as(isize, v));
}
fn readI32(p: [*]const u8) i32 {
    return std.mem.readInt(i32, p[0..4], .little);
}

const std = @import("std");
const dynlib = @import("dynlib.zig");
const zydis = @import("zydis");
