const Rerun = @This();

scheduled: std.time.Instant,
delay_ms: u32,

pub fn remainingMs(rerun: Rerun, now: std.time.Instant) u32 {
    const elapsed_ms = now.since(rerun.scheduled) / std.time.ns_per_ms;
    return @intCast(rerun.delay_ms -| @min(elapsed_ms, std.math.maxInt(u32)));
}

pub fn isDue(rerun: Rerun, now: std.time.Instant) bool {
    return rerun.remainingMs(now) == 0;
}

const std = @import("std");
