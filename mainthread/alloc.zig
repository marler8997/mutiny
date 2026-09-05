const global = struct {
    var mods: Pool(Mod) = .{};
    var scripts: Pool(Script) = .{};
    var general_instance: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
};

pub fn general() std.mem.Allocator {
    return global.general_instance.allocator();
}

pub fn newMod() error{OutOfMemory}!*Mod {
    return global.mods.create();
}
pub fn freeMod(mod: *Mod) void {
    global.mods.destroy(mod);
}

pub fn newScript() error{OutOfMemory}!*Script {
    return global.scripts.create();
}
pub fn freeScript(script: *Script) void {
    global.scripts.destroy(script);
}

const std = @import("std");
const mutiny = @import("mutiny");

const Mod = @import("Mod.zig");
const Pool = mutiny.Pool;
const Script = @import("Script.zig");
