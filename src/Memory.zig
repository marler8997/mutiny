const Memory = @This();

allocator: Allocator,
chunks: std.DoublyLinkedList = .{},

pub fn deinit(mem: *Memory) void {
    // std.debug.print("Memory deinit: enter\n", .{});
    const released = mem.discardFrom(.zero);
    _ = released;
    // std.debug.print("Memory deinit: released {} bytes\n", .{released});
    mem.* = undefined;
}

const chunk_metadata_size = std.mem.alignForward(usize, @sizeOf(Chunk), alignment);

const Chunk = struct {
    list_node: std.DoublyLinkedList.Node,
    alloc_size: usize,
    total_used: usize,
    pub fn getAllocation(chunk: *Chunk) []align(alignment) u8 {
        return @as([*]align(alignment) u8, @ptrCast(chunk))[0..chunk.alloc_size];
    }
};

pub const Addr = struct {
    node: ?*std.DoublyLinkedList.Node,
    offset: usize,

    pub const zero: Addr = .{ .node = null, .offset = 0 };

    pub fn format(addr: Addr, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (addr.node) |node| {
            std.debug.assert(addr.offset >= chunk_metadata_size);
            try writer.print("0x{x}({})", .{ @intFromPtr(node), addr.offset });
        } else {
            std.debug.assert(addr.offset == 0);
            try writer.print("0", .{});
        }
    }
    pub fn eql(addr1: Addr, addr2: Addr) bool {
        const addr1_node = addr1.node orelse {
            std.debug.assert(addr1.offset == 0);
            if (addr2.node == null) {
                std.debug.assert(addr2.offset == 0);
                return true;
            }
            std.debug.assert(addr2.offset >= chunk_metadata_size);
            return addr2.offset == chunk_metadata_size;
        };

        std.debug.assert(addr1.offset >= chunk_metadata_size);
        const addr2_node = addr2.node orelse {
            std.debug.assert(addr2.offset == 0);
            return addr1.offset == chunk_metadata_size and addr1_node.prev == null;
        };

        std.debug.assert(addr2.offset >= chunk_metadata_size);

        if (addr1_node == addr2_node) return addr1.offset == addr2.offset;

        const chunk1: *const Chunk = @fieldParentPtr("list_node", addr1_node);
        if (addr1.offset == chunk1.total_used and addr1_node.next == addr2_node and addr2.offset == chunk_metadata_size) {
            return true;
        }
        const chunk2: *const Chunk = @fieldParentPtr("list_node", addr2_node);
        if (addr2.offset == chunk2.total_used and addr2_node.next == addr1_node and addr1.offset == chunk_metadata_size) {
            return true;
        }

        return false;
    }
};

pub fn top(mem: *Memory) Addr {
    const last_node = mem.chunks.last orelse return .zero;
    const chunk: *Chunk = @fieldParentPtr("list_node", last_node);
    return .{ .node = last_node, .offset = chunk.total_used };
}

pub fn discardFrom(mem: *Memory, addr: Addr) usize {
    var total_discarded: usize = 0;
    const addr_node = addr.node orelse {
        // free everything!
        std.debug.assert(addr.offset == 0);
        var it = mem.chunks.last;
        while (it) |node| {
            // save this before freeing the chunk
            const prev = node.prev;
            const chunk: *Chunk = @fieldParentPtr("list_node", node);
            std.debug.assert(chunk.total_used >= chunk_metadata_size);
            total_discarded += chunk.total_used - chunk_metadata_size;
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // std.debug.print("Memory: free chunk 0x{x}\n", .{@intFromPtr(chunk)});
            mem.allocator.free(chunk.getAllocation());
            it = prev;
        }
        mem.chunks = .{};
        return total_discarded;
    };
    std.debug.assert(addr.offset >= chunk_metadata_size);

    var it = mem.chunks.last.?;
    while (true) {
        const chunk: *Chunk = @fieldParentPtr("list_node", it);
        std.debug.assert(chunk.total_used >= chunk_metadata_size);

        if (addr_node == it) {
            std.debug.assert(addr.offset <= chunk.total_used);
            total_discarded += chunk.total_used - addr.offset;
            chunk.total_used = addr.offset;
            return total_discarded;
        }

        // save this before freeing the chunk
        const prev = it.prev.?;
        total_discarded += chunk.total_used - chunk_metadata_size;
        mem.allocator.free(chunk.getAllocation());
        it = prev;
    }
}

pub fn toPointer(mem: *Memory, comptime T: type, addr: Addr) *T {
    comptime std.debug.assert(@alignOf(T) <= alignment);
    const aligned_sizeof_t = std.mem.alignForward(usize, @sizeOf(T), alignment);

    const node = addr.node orelse {
        std.debug.assert(addr.offset == 0);
        const chunk: *Chunk = @fieldParentPtr("list_node", mem.chunks.first.?);
        const allocation = chunk.getAllocation();
        std.debug.assert(chunk_metadata_size + aligned_sizeof_t <= chunk.total_used);
        return @ptrCast(@alignCast(&allocation[chunk_metadata_size]));
    };

    std.debug.assert(addr.offset >= chunk_metadata_size);
    const chunk: *Chunk = @fieldParentPtr("list_node", node);

    if (addr.offset < chunk.total_used) {
        std.debug.assert(addr.offset + aligned_sizeof_t <= chunk.total_used);
        const allocation = chunk.getAllocation();
        return @ptrCast(@alignCast(&allocation[addr.offset]));
    }

    std.debug.assert(addr.offset == chunk.total_used);
    const next_chunk: *Chunk = @fieldParentPtr("list_node", node.next.?);
    const allocation = next_chunk.getAllocation();
    std.debug.assert(chunk_metadata_size + aligned_sizeof_t <= next_chunk.total_used);
    return @ptrCast(@alignCast(&allocation[chunk_metadata_size]));
}

pub fn after(mem: *Memory, comptime T: type, addr: Addr) Addr {
    comptime std.debug.assert(@alignOf(T) <= alignment);
    const aligned_sizeof_t = std.mem.alignForward(usize, @sizeOf(T), alignment);

    const node = addr.node orelse {
        std.debug.assert(addr.offset == 0);
        const chunk: *Chunk = @fieldParentPtr("list_node", mem.chunks.first.?);
        std.debug.assert(chunk_metadata_size + aligned_sizeof_t <= chunk.total_used);
        return .{
            .node = &chunk.list_node,
            .offset = chunk_metadata_size + aligned_sizeof_t,
        };
    };

    std.debug.assert(addr.offset >= chunk_metadata_size);
    const chunk: *Chunk = @fieldParentPtr("list_node", node);
    std.debug.assert(addr.offset + aligned_sizeof_t <= chunk.total_used);
    return .{
        .node = &chunk.list_node,
        .offset = addr.offset + aligned_sizeof_t,
    };
}

const alignment = 8;
comptime {
    std.debug.assert(@alignOf(Chunk) <= alignment);
}

pub fn push(mem: *Memory, comptime T: type) error{OutOfMemory}!*T {
    comptime std.debug.assert(@alignOf(T) <= alignment);
    const aligned_size = std.mem.alignForward(usize, @sizeOf(T), alignment);

    if (mem.chunks.last) |last_node| {
        const chunk: *Chunk = @fieldParentPtr("list_node", last_node);
        // const used_aligned = std.mem.alignForward(usize, chunk.used, @alignOf(T));
        // const data = chunk.getData()[chunk.used..];
        const allocation = chunk.getAllocation();
        if (chunk.total_used + aligned_size <= allocation.len) {
            const offset = chunk.total_used;
            chunk.total_used += aligned_size;
            return @ptrCast(@alignCast(&allocation[offset]));
        }

        // try to resize the chunk in place
        const new_size = allocation.len + std.mem.alignForward(usize, aligned_size, std.heap.pageSize());
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // std.debug.print("attempting to resize chunk from size {} to {}\n", .{ allocation.len, new_size });
        if (std.heap.page_allocator.resize(allocation, new_size)) {
            chunk.alloc_size = new_size;
            std.debug.assert(chunk.total_used + aligned_size <= allocation.len);
            const offset = chunk.total_used;
            chunk.total_used += aligned_size;
            return @ptrCast(@alignCast(&allocation[offset]));
        }
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // std.debug.print("unable to resize, allocating new chunk\n", .{});
    }
    try mem.allocateChunk(aligned_size);
    std.debug.assert(mem.chunks.last != null);
    const chunk: *Chunk = @fieldParentPtr("list_node", mem.chunks.last.?);
    const allocation = chunk.getAllocation();
    std.debug.assert(chunk.total_used + aligned_size <= allocation.len);
    const offset = chunk.total_used;
    chunk.total_used += aligned_size;
    return @ptrCast(@alignCast(&allocation[offset]));
}

fn allocateChunk(mem: *Memory, min_capacity: usize) error{OutOfMemory}!void {
    const alloc_size = std.mem.alignForward(usize, @sizeOf(Chunk) + min_capacity, std.heap.pageSize());
    const chunk_mem = try mem.allocator.allocWithOptions(u8, alloc_size, .fromByteUnits(alignment), null);
    const chunk: *Chunk = @ptrCast(@alignCast(chunk_mem.ptr));
    chunk.* = .{
        .list_node = .{},
        .alloc_size = alloc_size,
        .total_used = chunk_metadata_size,
    };
    std.debug.assert(chunk.getAllocation().ptr == chunk_mem.ptr);
    std.debug.assert(chunk.getAllocation().len == chunk_mem.len);
    mem.chunks.append(&chunk.list_node);
}

test "Memory basic allocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var memory = Memory{ .allocator = allocator };
    defer memory.deinit();

    const ptr1 = try memory.push(u32);
    ptr1.* = 42;
    try testing.expectEqual(@as(u32, 42), ptr1.*);

    const ptr2 = try memory.push(u64);
    ptr2.* = 12345;
    try testing.expectEqual(@as(u64, 12345), ptr2.*);

    // First allocation should still be valid
    try testing.expectEqual(@as(u32, 42), ptr1.*);
}

test "Memory multiple chunks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var memory = Memory{ .allocator = allocator };
    defer memory.deinit();

    // Allocate many items to force multiple chunks
    var ptrs: [1000]*u64 = undefined;
    for (&ptrs, 0..) |*ptr, i| {
        ptr.* = try memory.push(u64);
        ptr.*.* = i;
    }

    // Verify all values are correct
    for (ptrs, 0..) |ptr, i| {
        try testing.expectEqual(@as(u64, i), ptr.*);
    }
}

test "Memory alignment" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var memory = Memory{ .allocator = allocator };
    defer memory.deinit();

    // Test different alignment requirements
    const ptr1 = try memory.push(u8);
    ptr1.* = 1;

    const ptr2 = try memory.push(u64);
    try testing.expect(@intFromPtr(ptr2) % @alignOf(u64) == 0);
    ptr2.* = 2;

    const ptr3 = try memory.push(u16);
    try testing.expect(@intFromPtr(ptr3) % @alignOf(u16) == 0);
    ptr3.* = 3;

    try testing.expectEqual(@as(u8, 1), ptr1.*);
    try testing.expectEqual(@as(u64, 2), ptr2.*);
    try testing.expectEqual(@as(u16, 3), ptr3.*);
}

test "Memory toPointer all cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mem = Memory{ .allocator = allocator };
    defer mem.deinit();

    try testing.expectEqual(Addr.zero, mem.top());

    // Case 1: null node with offset 0 - should point to first item in first chunk
    const ptr1 = try mem.push(u32);
    ptr1.* = 42;

    try testing.expectEqual(Addr{
        .node = mem.chunks.first,
        .offset = chunk_metadata_size + std.mem.alignForward(usize, @sizeOf(u32), alignment),
    }, mem.top());

    const null_ptr = mem.toPointer(u32, .zero);
    try testing.expectEqual(@as(u32, 42), null_ptr.*);
    try testing.expectEqual(ptr1, null_ptr);
    try testing.expectEqual(Addr{
        .node = mem.chunks.first,
        .offset = chunk_metadata_size + std.mem.alignForward(usize, @sizeOf(u32), alignment),
    }, mem.after(u32, .zero));

    // Case 2: normal address within a chunk
    const ptr2 = try mem.push(u64);
    ptr2.* = 12345;

    const normal_addr = Addr{
        .node = mem.chunks.first,
        .offset = chunk_metadata_size + std.mem.alignForward(usize, @sizeOf(u32), alignment),
    };
    const normal_ptr = mem.toPointer(u64, normal_addr);
    try testing.expectEqual(@as(u64, 12345), normal_ptr.*);
    try testing.expectEqual(ptr2, normal_ptr);
    try testing.expectEqual(Addr{
        .node = mem.chunks.first,
        .offset = chunk_metadata_size +
            std.mem.alignForward(usize, @sizeOf(u32), alignment) +
            std.mem.alignForward(usize, @sizeOf(u64), alignment),
    }, mem.after(u32, normal_addr));

    // Case 3: address at end of chunk - should point to first item in next chunk
    // Fill up the first chunk
    const last_chunk = mem.chunks.last;
    while (mem.chunks.last == last_chunk) {
        const value_ptr = try mem.push([alignment]u8);
        value_ptr.* = undefined;
    }

    const test_value: u32 = 0xa819a0b2;

    {
        const value_ptr = mem.toPointer(u32, .{
            .node = mem.chunks.last,
            .offset = chunk_metadata_size,
        });
        value_ptr.* = test_value;
    }

    const first_chunk: *Chunk = @fieldParentPtr("list_node", mem.chunks.first.?);
    const boundary_addr = Addr{
        .node = mem.chunks.first,
        .offset = first_chunk.total_used,
    };

    const boundary_ptr = mem.toPointer(u32, boundary_addr);
    try testing.expectEqual(test_value, boundary_ptr.*);
}

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
