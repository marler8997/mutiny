const ModEvent = @This();

list_node: std.DoublyLinkedList.Node,
name: BoundedArray(u8, ModNameSlice.max_len),
text: ?[]u8,

pub fn create(mod_name: ModNameSlice, text: ?[]u8) error{OutOfMemory}!*ModEvent {
    const event = try alloc.newModEvent();
    event.* = .{
        .list_node = .{},
        .name = .{ .len = mod_name.len, .buffer = undefined },
        .text = text,
    };
    @memcpy(event.name.buffer[0..mod_name.len], mod_name.slice());
    return event;
}

pub fn destroy(event: *ModEvent) void {
    if (event.text) |text| alloc.general().free(text);
    event.* = undefined;
    alloc.freeModEvent(event);
}

const std = @import("std");
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
