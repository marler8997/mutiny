const global = struct {
    var link_mutex: Mutex = .{};
    var list: std.DoublyLinkedList = .{};
};

pub const Request = union(enum) {
    file: []const u8,
    builtin: Builtin,
};

pub fn mutinyThreadQueue(
    pid: u32,
    pipe: PipeHandle,
    script_name: ModNameSlice,
    request: Request,
) error{OutOfMemory}!void {
    const kind: Script.Kind = switch (request) {
        .file => |content| .{ .file = .{ .text = try alloc.general().dupe(u8, content) } },
        .builtin => |b| .{ .builtin = b },
    };
    errdefer switch (kind) {
        .file => |f| alloc.general().free(f.text),
        .builtin => {},
    };
    const script = try alloc.newScript();
    script.* = .{
        .list_node = .{},
        .client = .{ .pid = pid, .pipe = pipe },
        .name = .{ .len = script_name.len, .buffer = undefined },
        .kind = kind,
    };
    @memcpy(script.name.buffer[0..script_name.len], script_name.slice());

    global.link_mutex.lock();
    defer global.link_mutex.unlock();
    global.list.append(&script.list_node);
}

pub fn steal() ?*Script {
    global.link_mutex.lock();
    defer global.link_mutex.unlock();
    const node = global.list.first orelse return null;
    global.list.remove(node);
    return @fieldParentPtr("list_node", node);
}

const std = @import("std");

const mainthread = @import("mainthread.zig");
const alloc = @import("alloc.zig");

const Builtin = mainthread.Builtin;
const ModNameSlice = @import("ModNameSlice.zig");
const Mutex = mainthread.Mutex;
const PipeHandle = Script.PipeHandle;
const Script = @import("Script.zig");
