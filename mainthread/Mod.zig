const Mod = @This();

list_node: std.DoublyLinkedList.Node,
name: BoundedArray(u8, ModNameSlice.max_len),
text: ?[]u8,
executed: bool,

pub fn create(mod_name: ModNameSlice, text: ?[]u8) error{OutOfMemory}!*Mod {
    const mod = try alloc.newMod();
    mod.* = .{
        .list_node = .{},
        .name = .{ .len = mod_name.len, .buffer = undefined },
        .text = text,
        .executed = false,
    };
    @memcpy(mod.name.buffer[0..mod_name.len], mod_name.slice());
    return mod;
}

pub fn destroy(mod: *Mod) void {
    if (mod.text) |text| alloc.general().free(text);
    mod.* = undefined;
    alloc.freeMod(mod);
}

const std = @import("std");
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
