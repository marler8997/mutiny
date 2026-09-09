const global = struct {
    var queue_mutex: Mutex = .{};
    var queue: std.DoublyLinkedList = .{};

    // no need to lock list, only accessed by the main thread
    var mod_list: std.DoublyLinkedList = .{};
};

pub fn ioThreadQueueUpdate(name: ModNameSlice, content: []const u8) error{OutOfMemory}!void {
    const text = try alloc.general().dupe(u8, content);
    errdefer alloc.general().free(text);
    queue(try ModEvent.create(name, text));
}

pub fn ioThreadQueueRemove(name: ModNameSlice) error{OutOfMemory}!void {
    queue(try ModEvent.create(name, null));
}

fn queue(event: *ModEvent) void {
    global.queue_mutex.lock();
    defer global.queue_mutex.unlock();
    global.queue.append(&event.list_node);
}

fn stealUpdate() ?*ModEvent {
    global.queue_mutex.lock();
    defer global.queue_mutex.unlock();
    const node = global.queue.first orelse return null;
    global.queue.remove(node);
    return @fieldParentPtr("list_node", node);
}

fn find(comptime T: type, list: *const std.DoublyLinkedList, mod_name: []const u8) ?*T {
    var maybe_node = list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const mod: *T = @fieldParentPtr("list_node", node);
        if (std.mem.eql(u8, mod.name.slice(), mod_name)) return mod;
    }
    return null;
}

pub fn applyUpdates(retired: *std.DoublyLinkedList) void {
    while (stealUpdate()) |update| applyModEvent(update, retired);
}

fn applyModEvent(update: *ModEvent, retired: *std.DoublyLinkedList) void {
    defer update.destroy();
    const existing = find(Mod, &global.mod_list, update.name.slice());
    if (update.text) |new_text| {
        const mod = Mod.create(update.name, new_text) catch |err| switch (err) {
            error.OutOfMemory => {
                std.log.err("mod '{s}' dropped: out of memory", .{update.name.slice()});
                return;
            },
        };
        update.text = null;
        if (existing) |old_mod| {
            std.log.info(
                "mod '{s}' updated ({} to {} bytes)",
                .{ old_mod.name.slice(), old_mod.text.len, new_text.len },
            );
            retire(old_mod, retired);
        } else {
            std.log.info("mod '{s}' loaded ({} bytes)", .{ update.name.slice(), new_text.len });
        }
        global.mod_list.append(&mod.list_node);
    } else {
        const mod = existing orelse std.debug.panic("remove for unknown mod '{s}'", .{update.name.slice()});
        std.log.info("deleting mod '{s}'", .{mod.name.slice()});
        retire(mod, retired);
    }
}

fn retire(mod: *Mod, retired: *std.DoublyLinkedList) void {
    global.mod_list.remove(&mod.list_node);
    retired.append(&mod.list_node);
}

pub fn findMod(name: []const u8) ?*Mod {
    return find(Mod, &global.mod_list, name);
}

pub const ModIterator = struct {
    node: ?*std.DoublyLinkedList.Node,
    pub fn next(it: *ModIterator) ?*Mod {
        while (it.node) |node| {
            it.node = node.next;
            const mod: *Mod = @fieldParentPtr("list_node", node);
            return mod;
        }
        return null;
    }
};
pub fn hasMods() bool {
    return global.mod_list.first != null;
}
pub fn modIterator() ModIterator {
    return .{ .node = global.mod_list.first };
}

const std = @import("std");
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");

const ModEvent = @import("ModEvent.zig");
const Mod = @import("Mod.zig");
const ModNameSlice = @import("ModNameSlice.zig");
const Mutex = mutiny.Mutex;
