const global = struct {
    var list: std.DoublyLinkedList = .{};
};

pub const Request = union(enum) {
    file: []u8,
    builtin: Builtin,
};

pub fn queue(
    pid: u32,
    pipe: PipeHandle,
    script_name: ModNameSlice,
    request: Request,
) error{OutOfMemory}!void {
    const kind: Script.Kind = switch (request) {
        .file => |text| .{ .file = .{ .text = text } },
        .builtin => |b| .{ .builtin = b },
    };
    const script = try alloc.newScript();
    script.* = .{
        .list_node = .{},
        .client = .{ .pid = pid, .pipe = pipe },
        .name = .{ .len = script_name.len, .buffer = undefined },
        .kind = kind,
    };
    @memcpy(script.name.buffer[0..script_name.len], script_name.slice());
    global.list.append(&script.list_node);
}

pub fn take() ?*Script {
    const node = global.list.first orelse return null;
    global.list.remove(node);
    return @fieldParentPtr("list_node", node);
}

const std = @import("std");

const mainthread = @import("mainthread.zig");
const alloc = @import("alloc.zig");

const Builtin = mainthread.Builtin;
const ModNameSlice = @import("ModNameSlice.zig");
const PipeHandle = Script.PipeHandle;
const Script = @import("Script.zig");
