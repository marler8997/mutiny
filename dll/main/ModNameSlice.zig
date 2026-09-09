const ModNameSlice = @This();

ptr: [*]const u8,
len: u8,

pub const max_len = std.math.maxInt(u8);

pub fn init(s: []const u8) ?ModNameSlice {
    return .{
        .ptr = s.ptr,
        .len = std.math.cast(u8, s.len) orelse return null,
    };
}
pub fn slice(s: ModNameSlice) []const u8 {
    return s.ptr[0..s.len];
}

const std = @import("std");
