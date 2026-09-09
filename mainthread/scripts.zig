const global = struct {
    var mutex: Mutex = .{};
    var loaded: std.DoublyLinkedList = .{};
};

pub const Request = union(enum) {
    file: []const u8,
    builtin: Builtin,
};

pub fn queue(
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
    global.mutex.lock();
    defer global.mutex.unlock();
    global.loaded.append(&script.list_node);
}

pub fn take() ?*Script {
    global.mutex.lock();
    defer global.mutex.unlock();
    const node = global.loaded.first orelse return null;
    global.loaded.remove(node);
    return @fieldParentPtr("list_node", node);
}

const std = @import("std");
const win32 = @import("win32").everything;

const mainthread = @import("mainthread.zig");
const alloc = @import("alloc.zig");

const BoundedArray = mainthread.BoundedArray;
const Builtin = mainthread.Builtin;
const ModNameSlice = @import("ModNameSlice.zig");
const Mutex = mainthread.Mutex;
const PipeHandle = Script.PipeHandle;
const Script = @import("Script.zig");
