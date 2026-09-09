const Script = @This();

list_node: std.DoublyLinkedList.Node,
client: Client,

name: BoundedArray(u8, ModNameSlice.max_len),
kind: Kind,

pub const Kind = union(enum) {
    file: struct { text: []u8 },
    builtin: Builtin,
};

pub const PipeHandle = if (builtin.os.tag == .windows) win32.HANDLE else std.posix.fd_t;

const Client = struct {
    pipe: PipeHandle,
    pid: u32,
};

pub fn deinit(script: *Script) void {
    switch (script.kind) {
        .file => |f| alloc.general().free(f.text),
        .builtin => {},
    }
    if (builtin.os.tag == .windows) {
        win32.closeHandle(script.client.pipe);
    } else {
        std.posix.close(script.client.pipe);
    }
    script.* = undefined;
    alloc.freeScript(script);
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");

const BoundedArray = mutiny.BoundedArray;
const Builtin = @import("builtins.zig").Builtin;
const ModNameSlice = @import("ModNameSlice.zig");
