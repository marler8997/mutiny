pub fn main() !u8 {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 3) {
        std.log.err("usage: mutinycompress IN_FILE OUT_FILE", .{});
        return 0xff;
    }
    const input = std.fs.cwd().readFileAlloc(arena, args[1], std.math.maxInt(usize)) catch |err| {
        std.log.err("read '{s}' failed with {t}", .{ args[1], err });
        return 0xff;
    };
    const bound = c.FL2_compressBound(input.len);
    const out = try arena.alloc(u8, bound);
    const len = c.FL2_compress(out.ptr, out.len, input.ptr, input.len, c.FL2_maxHighCLevel());
    const code = c.FL2_isError(len);
    if (code != 0) {
        std.log.err("compress '{s}' failed, error {} ({s})", .{ args[1], code, c.FL2_getErrorString(code) });
        return 0xff;
    }
    std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = out[0..len] }) catch |err| {
        std.log.err("write '{s}' failed with {t}", .{ args[2], err });
        return 0xff;
    };
    return 0;
}

const std = @import("std");
const c = @cImport({
    @cInclude("fast-lzma2.h");
    @cInclude("fl2_errors.h");
});
