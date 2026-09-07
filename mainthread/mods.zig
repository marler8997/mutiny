const global = struct {
    var queue_mutex: Mutex = .{};
    var queue: std.DoublyLinkedList = .{};

    // no need to lock list, only accessed by the main thread
    var list: std.DoublyLinkedList = .{};
};

pub fn mutinyThreadQueueUpdate(name: ModNameSlice, content: []const u8) error{OutOfMemory}!void {
    const text = try alloc.general().dupe(u8, content);
    errdefer alloc.general().free(text);
    queue(try Mod.create(name, text));
}

pub fn mutinyThreadQueueRemove(name: ModNameSlice) error{OutOfMemory}!void {
    queue(try Mod.create(name, null));
}

fn queue(mod: *Mod) void {
    global.queue_mutex.lock();
    defer global.queue_mutex.unlock();
    global.queue.append(&mod.list_node);
}

fn stealUpdate() ?*Mod {
    global.queue_mutex.lock();
    defer global.queue_mutex.unlock();
    const node = global.queue.first orelse return null;
    global.queue.remove(node);
    return @fieldParentPtr("list_node", node);
}

fn find(mod_name: []const u8) ?*Mod {
    var maybe_node = global.list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const mod: *Mod = @fieldParentPtr("list_node", node);
        if (std.mem.eql(u8, mod.name.slice(), mod_name)) return mod;
    }
    return null;
}

pub fn applyUpdates() void {
    while (stealUpdate()) |update| {
        const existing = find(update.name.slice());
        if (update.text) |new_text| {
            if (existing) |old_mod| {
                std.log.info(
                    "mod '{s}' updated ({} to {} bytes)",
                    .{ old_mod.name.slice(), old_mod.text.?.len, new_text.len },
                );
                global.list.remove(&old_mod.list_node);
                old_mod.destroy();
            } else {
                std.log.info("mod '{s}' loaded ({} bytes)", .{ update.name.slice(), new_text.len });
            }
            global.list.append(&update.list_node);
        } else {
            defer update.destroy();
            const mod = existing orelse std.debug.panic("remove for unknown mod '{s}'", .{update.name.slice()});
            std.log.info("deleting mod '{s}'", .{mod.name.slice()});
            global.list.remove(&mod.list_node);
            mod.destroy();
        }
    }
}

pub const Iterator = struct {
    node: ?*std.DoublyLinkedList.Node,
    pub fn next(it: *Iterator, now: std.time.Instant) ?*Mod {
        while (it.node) |node| {
            it.node = node.next;
            const mod: *Mod = @fieldParentPtr("list_node", node);
            switch (mod.run) {
                .pending => {},
                .done => continue,
                .rerun => |rerun| if (!rerun.isDue(now)) continue,
            }
            mod.run = .done;
            return mod;
        }
        return null;
    }
};
pub fn iterator() Iterator {
    return .{ .node = global.list.first };
}

pub fn nextRerunMs(now: std.time.Instant) ?u32 {
    var earliest: ?u32 = null;
    var maybe_node = global.list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const mod: *Mod = @fieldParentPtr("list_node", node);
        switch (mod.run) {
            .pending, .done => {},
            .rerun => |rerun| {
                const remaining = rerun.remainingMs(now);
                earliest = @min(earliest orelse remaining, remaining);
            },
        }
    }
    return earliest;
}

const std = @import("std");
const mainthread = @import("mainthread.zig");

const alloc = @import("alloc.zig");
const Mod = @import("Mod.zig");
const ModNameSlice = @import("ModNameSlice.zig");
const Mutex = mainthread.Mutex;
