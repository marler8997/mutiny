const ScheduledMod = @This();

list_node: std.DoublyLinkedList.Node,
name: BoundedArray(u8, ModNameSlice.max_len),
text: ?[]u8,
run: union(enum) {
    pending,
    done,
    reschedule: Reschedule,
},
is_first_run: bool,

pub fn create(mod_name: ModNameSlice, text: ?[]u8) error{OutOfMemory}!*ScheduledMod {
    const mod = try alloc.newScheduledMod();
    mod.* = .{
        .list_node = .{},
        .name = .{ .len = mod_name.len, .buffer = undefined },
        .text = text,
        .run = .pending,
        .is_first_run = true,
    };
    @memcpy(mod.name.buffer[0..mod_name.len], mod_name.slice());
    return mod;
}

pub fn destroy(mod: *ScheduledMod) void {
    if (mod.text) |text| alloc.general().free(text);
    mod.* = undefined;
    alloc.freeScheduledMod(mod);
}

const std = @import("std");
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
const Reschedule = @import("Reschedule.zig");
