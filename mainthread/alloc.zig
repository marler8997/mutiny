const global = struct {
    var scheduled_mods: Pool(ScheduledMod) = .{};
    var update_mods: Pool(UpdateMod) = .{};
    var scripts: Pool(Script) = .{};
    var general_instance: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
};

pub fn general() std.mem.Allocator {
    return global.general_instance.allocator();
}

pub fn newScheduledMod() error{OutOfMemory}!*ScheduledMod {
    return global.scheduled_mods.create();
}
pub fn freeScheduledMod(mod: *ScheduledMod) void {
    global.scheduled_mods.destroy(mod);
}

pub fn newUpdateMod() error{OutOfMemory}!*UpdateMod {
    return global.update_mods.create();
}
pub fn freeUpdateMod(mod: *UpdateMod) void {
    global.update_mods.destroy(mod);
}

pub fn newScript() error{OutOfMemory}!*Script {
    return global.scripts.create();
}
pub fn freeScript(script: *Script) void {
    global.scripts.destroy(script);
}

const std = @import("std");
const mutiny = @import("mutiny");

const ScheduledMod = @import("ScheduledMod.zig");
const Pool = mutiny.Pool;
const Script = @import("Script.zig");
const UpdateMod = @import("UpdateMod.zig");
