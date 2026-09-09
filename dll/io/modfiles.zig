const global = struct {
    var pool: Pool(ModFile) = .{};
    var list: std.DoublyLinkedList = .{};
};

pub const Update = union(enum) {
    err: ErrorNoText,
    content: []const u8,
};

fn findOrCreate(mod_name: ModNameSlice) error{OutOfMemory}!*ModFile {
    var maybe_node = global.list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const file: *ModFile = @fieldParentPtr("list_node", node);
        if (std.mem.eql(u8, file.name.slice(), mod_name.slice())) return file;
    }
    const file = try global.pool.create();
    file.* = .{
        .list_node = .{},
        .name = .{ .len = mod_name.len, .buffer = undefined },
        .stale = false,
        .last = .initial,
    };
    @memcpy(file.name.buffer[0..mod_name.len], mod_name.slice());
    global.list.append(&file.list_node);
    return file;
}

pub fn markStale() void {
    var maybe_node = global.list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const file: *ModFile = @fieldParentPtr("list_node", node);
        file.stale = true;
    }
}

pub fn deleteStale() bool {
    var queued = false;
    var maybe_node = global.list.first;
    while (maybe_node) |node| {
        maybe_node = node.next;
        const file: *ModFile = @fieldParentPtr("list_node", node);
        if (!file.stale) continue;
        switch (file.last) {
            .initial, .err => {},
            .text => mainthread.ioThreadQueueModRemove(file.nameSlice()) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.err("out of memory queueing removal of mod '{s}', will retry", .{file.name.slice()});
                    continue;
                },
            },
        }
        queued = true;
        global.list.remove(node);
        file.* = undefined;
        global.pool.destroy(file);
    }
    return queued;
}

pub fn update(mod_name: ModNameSlice, mod_update: Update) bool {
    const file = findOrCreate(mod_name) catch |err| switch (err) {
        error.OutOfMemory => {
            std.log.err("out of memory tracking mod '{s}', will retry", .{mod_name.slice()});
            return false;
        },
    };
    file.stale = false;
    switch (mod_update) {
        .content => |content| {
            const hash = std.hash.Wyhash.hash(0, content);
            switch (file.last) {
                .text => |last| if (last.hash == hash and last.len == content.len) return false,
                .initial, .err => {},
            }
            mainthread.ioThreadQueueModUpdate(mod_name, content) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.err("out of memory queueing mod '{s}', will retry", .{file.name.slice()});
                    return false;
                },
            };
            file.last = .{ .text = .{ .hash = hash, .len = content.len } };
            return true;
        },
        .err => |new_err| {
            switch (file.last) {
                .err => |last_err| if (last_err.eql(new_err)) return false,
                .initial, .text => {},
            }
            const had_text = file.last == .text;
            new_err.log(file.name.slice());
            if (had_text) mainthread.ioThreadQueueModRemove(mod_name) catch |err| switch (err) {
                error.OutOfMemory => {
                    std.log.err("out of memory queueing removal of mod '{s}', will retry", .{file.name.slice()});
                    return false;
                },
            };
            file.last = .{ .err = new_err };
            return had_text;
        },
    }
}

const std = @import("std");
const mainthread = @import("mainthread");

const Pool = mainthread.Pool;
const ErrorNoText = ModFile.ErrorNoText;
const ModFile = @import("ModFile.zig");
const ModNameSlice = mainthread.ModNameSlice;
