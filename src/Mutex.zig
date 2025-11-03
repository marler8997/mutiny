const Mutex = @This();

const std = @import("std");

impl: std.Thread.Mutex = .{},
locked_by: ?u32 = null,

pub fn lock(self: *Mutex) void {
    self.impl.lock();
    std.debug.assert(self.locked_by == null);
    self.locked_by = std.os.windows.GetCurrentThreadId();
}

pub fn unlock(self: *Mutex) void {
    std.debug.assert(self.locked_by == std.os.windows.GetCurrentThreadId());
    self.locked_by = null;
    self.impl.unlock();
}
