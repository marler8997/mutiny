const Mod = @This();

list_node: std.DoublyLinkedList.Node,
name: BoundedArray(u8, ModNameSlice.max_len),
text: []u8,
state: State,
enabled: bool,
status: BoundedArray(u8, status_max_len),
label: unitygui.ModLabel,
pub const status_max_len = std.math.maxInt(u8);
pub const State = union(enum) {
    ok,
    result: struct {
        wyhash: u64,
    },
    err: struct {
        error_wyhash: u64,
    },
};

pub fn create(name: BoundedArray(u8, ModNameSlice.max_len), text: []u8) error{OutOfMemory}!*Mod {
    const mod = try alloc.newMod();
    mod.* = .{
        .list_node = .{},
        .name = name,
        .text = text,
        .state = .ok,
        .enabled = true,
        .status = .{ .len = 0, .buffer = undefined },
        .label = .{},
    };
    mod.formatStatus("enabled", .{});
    return mod;
}

pub fn formatStatus(mod: *Mod, comptime fmt: []const u8, args: anytype) void {
    const ellipsis = "...";
    const text = std.fmt.bufPrint(mod.status.buffer[0 .. status_max_len - ellipsis.len], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => truncated: {
            @memcpy(mod.status.buffer[status_max_len - ellipsis.len ..], ellipsis);
            break :truncated mod.status.buffer[0..];
        },
    };
    mod.status.len = @intCast(text.len);
}

pub fn destroy(mod: *Mod, dotnet_funcs: *const dotnet.Funcs) void {
    mod.label.deinit(dotnet_funcs);
    alloc.general().free(mod.text);
    mod.* = undefined;
    alloc.freeMod(mod);
}

const std = @import("std");
const mutiny = @import("mutiny");
const dotnet = mutiny.dotnet;

const alloc = @import("alloc.zig");
const unitygui = @import("unitygui.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
