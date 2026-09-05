pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        mutex: Mutex = .{},
        arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
        free: std.DoublyLinkedList = .{},
        live: usize = 0,

        pub fn create(self: *Self) error{OutOfMemory}!*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const item: *T = if (self.free.first) |node| blk: {
                self.free.remove(node);
                break :blk @fieldParentPtr("list_node", node);
            } else try self.arena.allocator().create(T);
            self.live += 1;
            return item;
        }
        pub fn destroy(self: *Self, item: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.live > 0);
            self.live -= 1;
            item.list_node = .{};
            self.free.append(&item.list_node);
        }
    };
}

const std = @import("std");

const Mutex = @import("Mutex.zig");
