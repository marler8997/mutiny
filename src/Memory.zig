const Memory = @This();

allocator: Allocator,
chunks: std.DoublyLinkedList = .{},
// end: usize = 0,

pub fn deinit(self: *Memory) void {
    var it = self.chunks.last;
    while (it) |node| {
        // save this before freeing the chunk
        const prev = node.prev;
        const chunk: *Chunk = @fieldParentPtr("list_node", node);
        self.allocator.free(chunk.getAllocation());
        it = prev;
    }
    self.* = undefined;
}

const chunk_metadata_size = std.mem.alignForward(usize, @sizeOf(Chunk), alignment);

const Chunk = struct {
    list_node: std.DoublyLinkedList.Node,
    alloc_size: usize,
    total_used: usize,
    pub fn getAllocation(chunk: *Chunk) []align(alignment) u8 {
        // return @as([*]u8, @ptrCast(chunk))[0 .. @sizeOf(Chunk) + chunk.data_capacity];
        return @as([*]align(alignment) u8, @ptrCast(chunk))[0..chunk.alloc_size];
    }
    // pub fn getData(chunk: *Chunk) []align(alignment) u8 {
    //     // return @as([*]u8, @ptrCast(chunk))[@sizeOf(Chunk)..][0..chunk.data_capacity];
    //     return @as([*]align(alignment) u8, @ptrCast(chunk))[chunk_metadata_size..chunk.alloc_size];
    // }
};

pub const Addr = struct {
    node: ?*std.DoublyLinkedList.Node,
    offset: usize,
    pub fn eql(self: Addr, other: Addr) bool {
        return (self.node == other.node) and (self.offset == other.offset);
    }
};
pub fn top(mem: *Memory) Addr {
    if (mem.chunks.last) |last_node| {
        const chunk: *Chunk = @fieldParentPtr("list_node", last_node);
        return .{ .node = last_node, .offset = chunk.total_used };
    }
    return .{ .node = null, .offset = 0 };
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
    const testing = std.testing;
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
    const testing = std.testing;
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
    const testing = std.testing;
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

const std = @import("std");
const Allocator = std.mem.Allocator;
