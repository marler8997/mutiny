const Reschedule = @This();

scheduled: std.time.Instant,
delay_ms: u32,

pub fn remainingMs(reschedule: Reschedule, now: std.time.Instant) u32 {
    const elapsed_ms = now.since(reschedule.scheduled) / std.time.ns_per_ms;
    return @intCast(reschedule.delay_ms -| @min(elapsed_ms, std.math.maxInt(u32)));
}

pub fn isDue(reschedule: Reschedule, now: std.time.Instant) bool {
    return reschedule.remainingMs(now) == 0;
}

const std = @import("std");
