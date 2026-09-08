const global = struct {
    var queue_mutex: Mutex = .{};
    var queue: std.DoublyLinkedList = .{};

    // no need to lock list, only accessed by the main thread
    var scheduled_list: std.DoublyLinkedList = .{};
    var on_update_list: std.DoublyLinkedList = .{};
};

pub const on_update_prefix = "on-update-";

pub fn mutinyThreadQueueUpdate(name: ModNameSlice, content: []const u8) error{OutOfMemory}!void {
    const text = try alloc.general().dupe(u8, content);
    errdefer alloc.general().free(text);
    queue(try ScheduledMod.create(name, text));
}

pub fn mutinyThreadQueueRemove(name: ModNameSlice) error{OutOfMemory}!void {
    queue(try ScheduledMod.create(name, null));
}

fn queue(mod: *ScheduledMod) void {
    global.queue_mutex.lock();
    defer global.queue_mutex.unlock();
    global.queue.append(&mod.list_node);
}

fn stealUpdate() ?*ScheduledMod {
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

pub fn applyUpdates(dotnet_funcs: *const dotnet.Funcs) void {
    while (stealUpdate()) |update| {
        if (std.mem.startsWith(u8, update.name.slice(), on_update_prefix)) {
            applyUpdateModEvent(dotnet_funcs, update);
        } else {
            applyScheduledModEvent(update);
        }
    }
}

fn applyScheduledModEvent(update: *ScheduledMod) void {
    const existing = find(ScheduledMod, &global.scheduled_list, update.name.slice());
    if (update.text) |new_text| {
        if (existing) |old_mod| {
            std.log.info(
                "mod '{s}' updated ({} to {} bytes)",
                .{ old_mod.name.slice(), old_mod.text.?.len, new_text.len },
            );
            global.scheduled_list.remove(&old_mod.list_node);
            old_mod.destroy();
        } else {
            std.log.info("mod '{s}' loaded ({} bytes)", .{ update.name.slice(), new_text.len });
        }
        global.scheduled_list.append(&update.list_node);
    } else {
        defer update.destroy();
        const mod = existing orelse std.debug.panic("remove for unknown mod '{s}'", .{update.name.slice()});
        std.log.info("deleting mod '{s}'", .{mod.name.slice()});
        global.scheduled_list.remove(&mod.list_node);
        mod.destroy();
    }
}

fn applyUpdateModEvent(dotnet_funcs: *const dotnet.Funcs, update: *ScheduledMod) void {
    defer update.destroy();
    const existing = find(UpdateMod, &global.on_update_list, update.name.slice());
    if (update.text) |new_text| {
        const mod = UpdateMod.create(update.name, new_text) catch |err| switch (err) {
            error.OutOfMemory => {
                std.log.err("update mod '{s}' dropped: out of memory", .{update.name.slice()});
                return;
            },
        };
        update.text = null;
        if (existing) |old_mod| {
            std.log.info(
                "update mod '{s}' updated ({} to {} bytes)",
                .{ old_mod.name.slice(), old_mod.text.len, new_text.len },
            );
            global.on_update_list.remove(&old_mod.list_node);
            old_mod.destroy(dotnet_funcs);
        } else {
            std.log.info("update mod '{s}' loaded ({} bytes)", .{ update.name.slice(), new_text.len });
        }
        global.on_update_list.append(&mod.list_node);
    } else {
        const mod = existing orelse std.debug.panic("remove for unknown update mod '{s}'", .{update.name.slice()});
        std.log.info("deleting update mod '{s}'", .{mod.name.slice()});
        global.on_update_list.remove(&mod.list_node);
        mod.destroy(dotnet_funcs);
    }
}

pub const ScheduledIterator = struct {
    node: ?*std.DoublyLinkedList.Node,
    pub fn next(it: *ScheduledIterator, now: std.time.Instant) ?*ScheduledMod {
        while (it.node) |node| {
            it.node = node.next;
            const mod: *ScheduledMod = @fieldParentPtr("list_node", node);
            switch (mod.run) {
                .pending => {},
                .done => continue,
                .reschedule => |reschedule| if (!reschedule.isDue(now)) continue,
            }
            mod.run = .done;
            return mod;
        }
        return null;
    }
};
pub fn scheduledIterator() ScheduledIterator {
    return .{ .node = global.scheduled_list.first };
}

pub const OnUpdateIterator = struct {
    node: ?*std.DoublyLinkedList.Node,
    pub fn next(it: *OnUpdateIterator) ?*UpdateMod {
        while (it.node) |node| {
            it.node = node.next;
            const mod: *UpdateMod = @fieldParentPtr("list_node", node);
            return mod;
        }
        return null;
    }
};
pub fn hasUpdateMods() bool {
    return global.on_update_list.first != null;
}
pub fn onUpdateIterator() OnUpdateIterator {
    return .{ .node = global.on_update_list.first };
}

pub fn nextRescheduleMs(now: std.time.Instant) ?u32 {
    var earliest: ?u32 = null;
    var maybe_node = global.scheduled_list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const mod: *ScheduledMod = @fieldParentPtr("list_node", node);
        switch (mod.run) {
            .pending, .done => {},
            .reschedule => |reschedule| {
                const remaining = reschedule.remainingMs(now);
                earliest = @min(earliest orelse remaining, remaining);
            },
        }
    }
    return earliest;
}

const std = @import("std");
const mutiny = @import("mutiny");

const alloc = @import("alloc.zig");
const dotnet = mutiny.dotnet;
const mainthread = @import("mainthread.zig");

const ScheduledMod = @import("ScheduledMod.zig");
const UpdateMod = @import("UpdateMod.zig");
const ModNameSlice = @import("ModNameSlice.zig");
const Mutex = mainthread.Mutex;
