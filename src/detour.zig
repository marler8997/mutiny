pub const FindError = dynlib.GetProcError || error{
    ExportNotFound,
    NoJumpFound,
    NoTailJumpFound,
    DecodeInstructionFailed,
};

pub fn findTypeInfoFromTypeDefinitionIndex(module: dynlib.Module) FindError!usize {
    const image_get_class = try findFunction(module, "il2cpp_image_get_class");
    const from_handle = resolveJumps(try findTailJump(image_get_class, "il2cpp_image_get_class"));
    return resolveJumps(try findTailJump(from_handle, "MetadataCache::GetTypeInfoFromHandle"));
}

fn findTailJump(start: usize, label: [:0]const u8) FindError!usize {
    var addr = start;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var status: zydis.Status = undefined;
        var instr: zydis.DecodedInstruction = undefined;
        var operands: [zydis.max_operand_count]zydis.DecodedOperand = undefined;
        zydis.decodeFull(&status, @ptrFromInt(addr), &instr, &operands) catch {
            logErr("detour: failed to decode instruction at 0x{x} locating the tail jump of '{s}': {f}", .{ addr, label, status });
            return error.DecodeInstructionFailed;
        };
        if (instr.mnemonic == zydis.mnemonic_ret) return error.NoTailJumpFound;
        if (instr.mnemonic == zydis.mnemonic_jmp) {
            if (zydis.relativeBranchTarget(&instr, &operands, addr)) |target| return target;
            return error.NoTailJumpFound;
        }
        addr += instr.length;
    }
    return error.NoTailJumpFound;
}

fn resolveJumps(start: usize) usize {
    var addr = start;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        addr = followJump(addr) orelse return addr;
    }
    return addr;
}

pub fn findFunction(module: dynlib.Module, export_name: [:0]const u8) FindError!usize {
    const proc_addr: usize = @intFromPtr(try dynlib.getProc(module, export_name));
    var next_addr: usize = proc_addr;
    var scanned: usize = 0;
    while (scanned < 32) {
        if (followJump(next_addr)) |target| return target;
        const ptr: [*]const u8 = @ptrFromInt(next_addr);
        var status: zydis.Status = undefined;
        const len = zydis.instructionLength(&status, ptr) catch {
            logErr(
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

// How far past the target to look for a branch back into the bytes the hook displaces. A branch that
// lands that early comes from a loop in a method small enough to have almost no prologue.
const branch_scan_len = 4096;

/// The answers of the DetourInstall export, which the README documents.
pub const DetourInstallResult = enum(u32) {
    ok = 0,
    not_ready = 1,
    wrong_thread = 2,
    failed = 3,
};
pub const DetourInstallFunction = *const fn (target: usize, hook: usize, out_trampoline: *usize) callconv(.c) DetourInstallResult;

pub const Detour = struct {
    /// executable memory: the target's displaced prologue followed by a jump back into it. Call this,
    /// typed as the original function, to invoke the original.
    trampoline: usize,
};

pub const InstallError = error{
    AlreadyPatched,
    TargetTooShort,
    PrologueMayFault,
    BranchIntoPatch,
    RelocateFailed,
    OutOfMemory,
} || PatchError;

pub fn install(target: usize, hook: usize) InstallError!Detour {
    return installWith(target, hook, .{ .managed = false }, allocTrampoline);
}

/// `install` for a game method on either runtime. A displaced instruction runs from the trampoline,
/// which the runtime has no information about. On mono a null check there would kill the process rather
/// than throw a NullReferenceException, and on both an exception couldn't unwind through a call whose
/// return address is there. So this refuses a prologue with either.
pub fn installManaged(target: usize, hook: usize) InstallError!Detour {
    return installWith(target, hook, .{ .managed = true }, allocTrampoline);
}

fn allocTrampoline(near: usize, size: usize) ?[*]u8 {
    // Nearness only matters for a relative prologue instruction, and if one can't reach from a far
    // trampoline its re-encode below fails before the target is patched. The jump back is absolute.
    return allocExecutable(near, size) orelse allocAnywhere(size);
}

fn installWith(
    target: usize,
    hook: usize,
    options: struct { managed: bool },
    alloc: *const fn (near: usize, size: usize) ?[*]u8,
) InstallError!Detour {
    var displaced: usize = 0;
    while (displaced < abs_jump_len) {
        var status: zydis.Status = undefined;
        var instr: zydis.DecodedInstruction = undefined;
        var operands: [zydis.max_operand_count]zydis.DecodedOperand = undefined;
        zydis.decodeFull(&status, @ptrFromInt(target + displaced), &instr, &operands) catch {
            logErr("detour: prologue decode failed at 0x{x}: {f}", .{ target + displaced, status });
            return error.RelocateFailed;
        };
        if (zydis.endsCode(&instr)) {
            if (displaced == 0 and instr.mnemonic == zydis.mnemonic_jmp) {
                // We could support chaining onto another tool's patch by relocating this jump into the
                // trampoline, if we find a valid use case for it.
                logErr("detour: 0x{x} starts with a jump, so it's already patched or just a thunk", .{target});
                return error.AlreadyPatched;
            }
            logErr("detour: 0x{x} ends {} bytes in, too short for the {} byte hook", .{ target, displaced, abs_jump_len });
            return error.TargetTooShort;
        }
        if (options.managed and zydis.mayFaultOrCall(&instr, &operands)) {
            logErr("detour: 0x{x} has an instruction that can fault or call {} bytes in, which the hook would displace", .{ target, displaced });
            return error.PrologueMayFault;
        }
        displaced += instr.length;
    }
    if (findBranchIntoPatch(target, displaced)) |branch| {
        logErr("detour: a branch at 0x{x} lands inside the {} bytes the hook would displace from 0x{x}", .{ branch, displaced, target });
        return error.BranchIntoPatch;
    }

    const tramp_size = displaced * zydis.max_instruction + abs_jump_len;
    const tramp = alloc(target, tramp_size) orelse {
        logErr("detour: no executable memory for a trampoline for 0x{x}", .{target});
        return error.OutOfMemory;
    };
    errdefer freeExecutable(tramp);

    var src_off: usize = 0;
    var dst_off: usize = 0;
    while (src_off < displaced) {
        const src = target + src_off;
        var instr: zydis.DecodedInstruction = undefined;
        var operands: [zydis.max_operand_count]zydis.DecodedOperand = undefined;
        {
            var status: zydis.Status = undefined;
            zydis.decodeFull(&status, @ptrFromInt(src), &instr, &operands) catch {
                logErr("detour: prologue decode failed at 0x{x}: {f}", .{ src, status });
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
                logErr("detour: prologue relocate failed at 0x{x}: {f}", .{ src, status });
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

/// The address of a relative branch that would land in the middle of the patch. The method ends at the
/// first ret or jmp that no earlier branch jumps past. What follows it is padding or another method,
/// and decoding that can turn up a branch that isn't real.
fn findBranchIntoPatch(target: usize, displaced: usize) ?usize {
    var region: win32.MEMORY_BASIC_INFORMATION = undefined;
    if (win32.VirtualQuery(@ptrFromInt(target), &region, @sizeOf(@TypeOf(region))) == 0)
        win32.panicWin32("detour: VirtualQuery", win32.GetLastError());
    const end = @min(target + branch_scan_len, @intFromPtr(region.BaseAddress) + region.RegionSize -| zydis.max_instruction);

    var addr = target;
    var furthest = target;
    while (addr < end) {
        var status: zydis.Status = undefined;
        var instr: zydis.DecodedInstruction = undefined;
        var operands: [zydis.max_operand_count]zydis.DecodedOperand = undefined;
        zydis.decodeFull(&status, @ptrFromInt(addr), &instr, &operands) catch return null;
        if (zydis.relativeBranchTarget(&instr, &operands, addr)) |dest| {
            if (dest > target and dest < target + displaced) return addr;
            if (instr.mnemonic != zydis.mnemonic_call) furthest = @max(furthest, dest);
        }
        addr += instr.length;
        if (zydis.endsCode(&instr) and addr > furthest) return null;
    }
    return null;
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
                logErr("detour: VirtualQuery(0x{x}) failed, error={f}", .{ up, win32.GetLastError() });
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
                logErr("detour: VirtualQuery(0x{x}) failed, error={f}", .{ down, win32.GetLastError() });
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

fn allocAnywhere(size: usize) ?[*]u8 {
    std.log.info("detour: no free memory within 2GB of the target, the trampoline will be far from it", .{});
    return allocAt(0, size);
}

fn freeExecutable(mem: [*]u8) void {
    if (win32.VirtualFree(mem, 0, win32.MEM_RELEASE) == 0) {
        logErr("detour: VirtualFree(0x{x}) failed, error={f}", .{ @intFromPtr(mem), win32.GetLastError() });
    }
}

fn allocAt(addr: usize, size: usize) ?[*]u8 {
    const mem = win32.VirtualAlloc(
        @ptrFromInt(addr),
        size,
        .{ .COMMIT = 1, .RESERVE = 1 },
        win32.PAGE_EXECUTE_READWRITE,
    ) orelse {
        logErr("detour: VirtualAlloc(0x{x}, {}) failed, error={f}", .{ addr, size, win32.GetLastError() });
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
        logErr("detour: VirtualProtect(0x{x}) failed, error={f}", .{ dst, win32.GetLastError() });
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

// The test runner fails any test that logs an error, and these tests hit the refusals on purpose.
const logErr = if (builtin.is_test) struct {
    fn log(comptime format: []const u8, args: anytype) void {
        _ = format;
        _ = args;
    }
}.log else std.log.err;

const tests = struct {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectError = std.testing.expectError;
    const nops = [_]u8{0x90} ** abs_jump_len;
    const identity_tail = [_]u8{ 0x48, 0x89, 0xc8, 0xc3 }; // mov rax, rcx; ret
    const Function = *const fn (usize) callconv(.c) usize;

    fn code(bytes: []const u8) ![*]u8 {
        const mem = allocAt(0, 4096) orelse return error.OutOfMemory;
        @memcpy(mem[0..bytes.len], bytes);
        return mem;
    }
    var trampoline: Function = undefined;
    fn plus1000(v: usize) callconv(.c) usize {
        return trampoline(v) + 1000;
    }
    fn isFree(mem: usize) bool {
        var info: win32.MEMORY_BASIC_INFORMATION = undefined;
        std.debug.assert(win32.VirtualQuery(@ptrFromInt(mem), &info, @sizeOf(@TypeOf(info))) != 0);
        return info.State.FREE == 1;
    }

    var far_alloc: usize = 0;
    /// A trampoline out of range of a 32-bit offset from `near`.
    fn allocFar(near: usize, size: usize) ?[*]u8 {
        var hint = std.mem.alignForward(usize, near, 0x10000) + 0x1_0000_0000;
        var attempts: usize = 0;
        while (attempts < 1024) : ({
            attempts += 1;
            hint += 0x1000_0000;
        }) {
            const mem = win32.VirtualAlloc(
                @ptrFromInt(hint),
                size,
                .{ .COMMIT = 1, .RESERVE = 1 },
                win32.PAGE_EXECUTE_READWRITE,
            ) orelse continue;
            far_alloc = @intFromPtr(mem);
            return @ptrCast(mem);
        }
        return null;
    }

    test "a hook runs in place of the target, and the trampoline runs the original" {
        const target = try code(&nops ++ identity_tail);
        const installed = try install(@intFromPtr(target), @intFromPtr(&plus1000));
        trampoline = @ptrFromInt(installed.trampoline);
        const hooked: Function = @ptrCast(target);
        try expectEqual(@as(usize, 1005), hooked(5));
        try expectEqual(@as(usize, 5), trampoline(5));
    }

    test "a second hook on a target is refused and leaves the first in place" {
        const target = try code(&nops ++ identity_tail);
        const installed = try install(@intFromPtr(target), @intFromPtr(&plus1000));
        trampoline = @ptrFromInt(installed.trampoline);
        try expectError(error.AlreadyPatched, install(@intFromPtr(target), @intFromPtr(&plus1000)));
        const hooked: Function = @ptrCast(target);
        try expectEqual(@as(usize, 1005), hooked(5));
    }

    test "a target another tool already patched is refused and left alone" {
        const shapes = [_][]const u8{
            &.{ 0xeb, 0x10 }, // jmp rel8
            &.{ 0xe9, 0x10, 0, 0, 0 }, // jmp rel32
            &.{ 0xff, 0x25, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 }, // jmp [rip+0], then the address
        };
        for (shapes) |shape| {
            const target = try code(shape);
            try expectError(error.AlreadyPatched, install(@intFromPtr(target), @intFromPtr(&plus1000)));
            try std.testing.expectEqualSlices(u8, shape, target[0..shape.len]);
        }
    }

    test "a target that ends inside the hook's bytes is refused and left alone" {
        const shapes = [_][]const u8{
            &identity_tail, // ret
            &.{ 0x90, 0xcc, 0x90 }, // int3
            &.{ 0x90, 0x0f, 0x0b }, // ud2
            &.{ 0x90, 0xf4 }, // hlt
            &.{ 0x90, 0xeb, 0x10 }, // jmp rel8
            &.{ 0x90, 0xe9, 0x10, 0, 0, 0 }, // jmp rel32
        };
        for (shapes) |shape| {
            const target = try code(shape);
            try expectError(error.TargetTooShort, install(@intFromPtr(target), @intFromPtr(&plus1000)));
            try std.testing.expectEqualSlices(u8, shape, target[0..shape.len]);
        }
    }

    test "installManaged refuses a prologue that could fault or call, install doesn't" {
        const shapes = [_][]const u8{
            &.{ 0x48, 0x8b, 0x41, 0x18 }, // mov rax, [rcx+0x18]
            &.{ 0x48, 0x83, 0x39, 0x00 }, // cmp qword [rcx], 0
            &.{ 0xe8, 0x10, 0, 0, 0 }, // call rel32
            &.{ 0x48, 0xab }, // stosq, which writes to an implicit [rdi]
            &.{ 0x48, 0x8b, 0x04, 0x0c }, // mov rax, [rsp+rcx]
            &.{ 0x64, 0x48, 0x8b, 0x04, 0x24 }, // mov rax, fs:[rsp]
            &.{ 0x48, 0xf7, 0xf1 }, // div rcx
        };
        for (shapes) |shape| {
            const target = try code(shape);
            @memset(target[shape.len..][0..abs_jump_len], 0x90);
            try expectError(error.PrologueMayFault, installManaged(@intFromPtr(target), @intFromPtr(&plus1000)));
            try std.testing.expectEqualSlices(u8, shape, target[0..shape.len]);
            _ = try install(@intFromPtr(target), @intFromPtr(&plus1000));
        }
    }

    test "installManaged accepts stack and rip-relative accesses and lea" {
        const shapes = [_][]const u8{
            &.{0x55}, // push rbp
            &.{ 0x48, 0x89, 0x34, 0x24 }, // mov [rsp], rsi
            &.{ 0x48, 0x8b, 0x45, 0xf8 }, // mov rax, [rbp-8]
            &.{ 0x48, 0x8b, 0x05, 0x10, 0, 0, 0 }, // mov rax, [rip+0x10]
            &.{ 0x48, 0x8d, 0x41, 0x18 }, // lea rax, [rcx+0x18]
        };
        for (shapes) |shape| {
            const target = try code(shape);
            @memset(target[shape.len..][0..abs_jump_len], 0x90);
            _ = try installManaged(@intFromPtr(target), @intFromPtr(&plus1000));
        }
    }

    test "a branch into the displaced bytes is refused and leaves the target alone" {
        const shapes = [_][]const u8{
            &nops ++ [_]u8{ 0x75, 0xf4 }, // jne +4
            &nops ++ [_]u8{ 0x0f, 0x85, 0xf9, 0xff, 0xff, 0xff }, // jne rel32 +13
            &nops ++ [_]u8{ 0x74, 0x01, 0xc3, 0x75, 0xf1 }, // je past a ret, then jne +4
            &[_]u8{ 0x0f, 0x84, 0x02, 0, 0, 0 } ++ nops, // je +8, from inside the displaced bytes
        };
        for (shapes) |shape| {
            const target = try code(shape);
            try expectError(error.BranchIntoPatch, install(@intFromPtr(target), @intFromPtr(&plus1000)));
            try std.testing.expectEqualSlices(u8, shape, target[0..shape.len]);
        }
    }

    test "a branch to the start of the target or past the displaced bytes is accepted" {
        const shapes = [_][]const u8{
            &nops ++ [_]u8{ 0x75, 0xf0 }, // jne +0
            &nops ++ [_]u8{ 0x75, 0xfe }, // jne +14
            &nops ++ [_]u8{ 0xc3, 0x75, 0xf3 }, // past the end of the method
        };
        for (shapes) |shape| {
            const target = try code(shape);
            _ = try install(@intFromPtr(target), @intFromPtr(&plus1000));
        }
    }

    test "a far trampoline works, because the jump back is absolute" {
        const target = try code(&[_]u8{ 0x48, 0x89, 0xc8, 0x90 } ++ nops ++ [_]u8{0xc3}); // mov rax, rcx; nops; ret
        const installed = try installWith(@intFromPtr(target), @intFromPtr(&plus1000), .{ .managed = false }, allocFar);
        const distance = if (installed.trampoline > @intFromPtr(target))
            installed.trampoline - @intFromPtr(target)
        else
            @intFromPtr(target) - installed.trampoline;
        try expect(distance > 0x8000_0000);
        trampoline = @ptrFromInt(installed.trampoline);
        const hooked: Function = @ptrCast(target);
        try expectEqual(@as(usize, 1005), hooked(5));
    }

    test "a relative instruction that can't reach a far trampoline fails, frees it and patches nothing" {
        const bytes = [_]u8{ 0x48, 0x8d, 0x05, 0x10, 0, 0, 0 } ++ nops ++ [_]u8{0xc3}; // lea rax, [rip+0x10]
        const target = try code(&bytes);
        try expectError(
            error.RelocateFailed,
            installWith(@intFromPtr(target), @intFromPtr(&plus1000), .{ .managed = false }, allocFar),
        );
        try std.testing.expectEqualSlices(u8, &bytes, target[0..bytes.len]);
        try expect(isFree(far_alloc));
    }
};

test {
    _ = tests;
}

const builtin = @import("builtin");
const std = @import("std");
const dynlib = @import("dynlib.zig");
const zydis = @import("zydis");
const win32 = @import("win32").everything;
