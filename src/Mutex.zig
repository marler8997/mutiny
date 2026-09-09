const Mutex = @This();

const std = @import("std");

impl: std.Thread.Mutex = .{},
locked_by: ?std.Thread.Id = null,

pub fn lock(self: *Mutex) void {
    self.impl.lock();
    std.debug.assert(self.locked_by == null);
    self.locked_by = std.Thread.getCurrentId();
}

pub fn unlock(self: *Mutex) void {
    std.debug.assert(self.locked_by == std.Thread.getCurrentId());
    self.locked_by = null;
    self.impl.unlock();
}
