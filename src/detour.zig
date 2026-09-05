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
        var status: zydis.Status = undefined;
        const len = zydis.instructionLength(&status, ptr) catch {
            std.log.err(
                "detour: failed to decode instruction 0x{x} at 0x{x} locating '{s}': {f}",
                .{ ptr[0..zydis.max_instruction], next_addr, export_name, status },
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

// FF 25 00000000 <8-byte absolute target> == `jmp qword [rip+0]`: a position-independent absolute
// jump that clobbers no register, so it reaches our hook however far it is from GameAssembly.dll.
const abs_jump_len = 14;

pub const Detour = struct {
    /// executable memory: the target's displaced prologue followed by a jump back into it. Call this,
    /// typed as the original function, to invoke the original.
    trampoline: usize,
};

pub const InstallError = error{ RelocateFailed, OutOfMemory } || PatchError;

pub fn install(target: usize, hook: usize) InstallError!Detour {
    var displaced: usize = 0;
    while (displaced < abs_jump_len) {
        var status: zydis.Status = undefined;
        displaced += zydis.instructionLength(&status, @ptrFromInt(target + displaced)) catch {
            std.log.err("detour: prologue decode failed at 0x{x}: {f}", .{ target + displaced, status });
            return error.RelocateFailed;
        };
    }

    const tramp_size = displaced * zydis.max_instruction + abs_jump_len;
    const tramp = allocExecutable(target, tramp_size) orelse {
        std.log.err("detour: no executable memory within 2GB of 0x{x}", .{target});
        return error.OutOfMemory;
    };

    var src_off: usize = 0;
    var dst_off: usize = 0;
    while (src_off < displaced) {
        const src = target + src_off;
        var instr: zydis.DecodedInstruction = undefined;
        var operands: [zydis.max_operand_count]zydis.DecodedOperand = undefined;
        {
            var status: zydis.Status = undefined;
            zydis.decodeFull(&status, @ptrFromInt(src), &instr, &operands) catch {
                std.log.err("detour: prologue decode failed at 0x{x}: {f}", .{ src, status });
                return error.RelocateFailed;
            };
        }
        {
            var status: zydis.Status = undefined;
            dst_off += zydis.reencode(
                &status,
                &instr,
                &operands,
                src,
                tramp[dst_off..tramp_size],
                @intFromPtr(tramp) + dst_off,
            ) catch {
                std.log.err("detour: prologue relocate failed at 0x{x}: {f}", .{ src, status });
                return error.RelocateFailed;
            };
        }
        src_off += instr.length;
    }
    writeAbsJump(tramp + dst_off, target + displaced);

    var patch: [abs_jump_len + zydis.max_instruction]u8 = undefined;
    writeAbsJump(&patch, hook);
    @memset(patch[abs_jump_len..displaced], 0x90);
    try patchCode(target, patch[0..displaced]);

    return .{ .trampoline = @intFromPtr(tramp) };
}

fn writeAbsJump(dst: [*]u8, dest_addr: usize) void {
    dst[0] = 0xff;
    dst[1] = 0x25;
    std.mem.writeInt(u32, dst[2..6], 0, .little); // rip-relative disp32 = 0; the address follows
    std.mem.writeInt(u64, dst[6..14], dest_addr, .little);
}

fn allocExecutable(near: usize, size: usize) ?[*]u8 {
    if (builtin.os.tag == .windows) {
        const granularity = 0x10000;
        const max_delta = 0x7fff_0000;

        var sysinfo: win32.SYSTEM_INFO = undefined;
        win32.GetSystemInfo(&sysinfo);
        const min_addr = @intFromPtr(sysinfo.lpMinimumApplicationAddress);
        const max_addr = @intFromPtr(sysinfo.lpMaximumApplicationAddress);

        const up_limit = @min(near + max_delta, max_addr);
        var up = std.mem.alignForward(usize, near, granularity);
        while (up + size <= up_limit) {
            var mbi: win32.MEMORY_BASIC_INFORMATION = undefined;
            if (win32.VirtualQuery(@ptrFromInt(up), &mbi, @sizeOf(@TypeOf(mbi))) == 0) {
                std.log.err("detour: VirtualQuery(0x{x}) failed, error={f}", .{ up, win32.GetLastError() });
                break;
            }
            const base = @intFromPtr(mbi.BaseAddress);
            if (mbi.State.FREE == 1 and up + size <= base + mbi.RegionSize) {
                if (allocAt(up, size)) |p| return p;
            }
            up = std.mem.alignForward(usize, base + mbi.RegionSize, granularity);
        }

        const down_limit = @max(near -| max_delta, min_addr);
        var down = std.mem.alignBackward(usize, near, granularity);
        while (down >= down_limit) {
            var mbi: win32.MEMORY_BASIC_INFORMATION = undefined;
            if (win32.VirtualQuery(@ptrFromInt(down), &mbi, @sizeOf(@TypeOf(mbi))) == 0) {
                std.log.err("detour: VirtualQuery(0x{x}) failed, error={f}", .{ down, win32.GetLastError() });
                break;
            }
            const base = @intFromPtr(mbi.BaseAddress);
            if (mbi.State.FREE == 1 and down + size <= base + mbi.RegionSize) {
                if (allocAt(down, size)) |p| return p;
            }
            if (base < granularity) break;
            down = std.mem.alignBackward(usize, base - 1, granularity);
        }
        return null;
    } else @panic("todo");
}

fn allocAt(addr: usize, size: usize) ?[*]u8 {
    const mem = win32.VirtualAlloc(
        @ptrFromInt(addr),
        size,
        .{ .COMMIT = 1, .RESERVE = 1 },
        win32.PAGE_EXECUTE_READWRITE,
    ) orelse {
        std.log.err("detour: VirtualAlloc(0x{x}, {}) failed, error={f}", .{ addr, size, win32.GetLastError() });
        return null;
    };
    return @ptrCast(mem);
}

pub const PatchError = error{ProtectFailed};

// overwrite executable code at `dst` with `bytes`, restoring the page protection and flushing the
// instruction cache afterward.
fn patchCode(dst: usize, bytes: []const u8) PatchError!void {
    if (builtin.os.tag != .windows) @compileError("todo: patchCode for this OS (mprotect)");
    var old: win32.PAGE_PROTECTION_FLAGS = undefined;
    if (win32.VirtualProtect(@ptrFromInt(dst), bytes.len, win32.PAGE_EXECUTE_READWRITE, &old) == 0) {
        std.log.err("detour: VirtualProtect(0x{x}) failed, error={f}", .{ dst, win32.GetLastError() });
        return error.ProtectFailed;
    }
    @memcpy(@as([*]u8, @ptrFromInt(dst))[0..bytes.len], bytes);
    // The following VirtualProtect and FlushInstructionCache should never fail in this situation,
    // and if they do, recovery would be complicated...panic will prove if we're wrong.
    if (win32.VirtualProtect(@ptrFromInt(dst), bytes.len, old, &old) == 0)
        win32.panicWin32("detour: VirtualProtect restore", win32.GetLastError());
    if (win32.FlushInstructionCache(win32.GetCurrentProcess(), @ptrFromInt(dst), bytes.len) == 0)
        win32.panicWin32("detour: FlushInstructionCache", win32.GetLastError());
}

const builtin = @import("builtin");
const std = @import("std");
const dynlib = @import("dynlib.zig");
const zydis = @import("zydis");
const win32 = @import("win32").everything;
