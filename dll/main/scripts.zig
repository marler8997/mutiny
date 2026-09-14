const global = struct {
    var mutex: Mutex = .{};
    var loaded: std.DoublyLinkedList = .{};
};

pub fn queue(
    pid: u32,
    pipe: PipeHandle,
    script_name: ModNameSlice,
    content: []const u8,
) error{OutOfMemory}!void {
    const text = try alloc.general().dupe(u8, content);
    errdefer alloc.general().free(text);
    const script = try alloc.newScript();
    script.* = .{
        .list_node = .{},
        .client = .{ .pid = pid, .pipe = pipe },
        .name = .{ .len = script_name.len, .buffer = undefined },
        .text = text,
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

const mutiny = @import("mutiny");
const alloc = @import("alloc.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
const Mutex = mutiny.Mutex;
const PipeHandle = Script.PipeHandle;
const Script = @import("Script.zig");
