const UpdateMod = @This();

list_node: std.DoublyLinkedList.Node,
name: BoundedArray(u8, ModNameSlice.max_len),
text: []u8,
state: State,
pub const State = union(enum) {
    ok,
    err: struct {
        error_wyhash: u64,
    },
    rerun_requested,
};

pub fn create(name: BoundedArray(u8, ModNameSlice.max_len), text: []u8) error{OutOfMemory}!*UpdateMod {
    const mod = try alloc.newUpdateMod();
    mod.* = .{
        .list_node = .{},
        .name = name,
        .text = text,
        .state = .ok,
    };
    return mod;
}

pub fn destroy(mod: *UpdateMod) void {
    alloc.general().free(mod.text);
    mod.* = undefined;
    alloc.freeUpdateMod(mod);
}

const std = @import("std");
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
