const Error = @This();

what: [:0]const u8,
err: union(enum) {
    any: anyerror,
    win32: win32.WIN32_ERROR,
},

pub fn initAny(what: [:0]const u8, any: anyerror) Error {
    return .{ .what = what, .err = .{ .any = any } };
}
pub fn initWin32(what: [:0]const u8, code: win32.WIN32_ERROR) Error {
    return .{ .what = what, .err = .{ .win32 = code } };
}

pub fn setAny(self: *Error, what: [:0]const u8, any: anyerror) error{Error} {
    self.* = .{ .what = what, .err = .{ .any = any } };
    return error.Error;
}
pub fn setWin32(self: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
    self.* = .{ .what = what, .err = .{ .win32 = code } };
    return error.Error;
}

pub fn format(self: Error, writer: *std.Io.Writer) error{WriteFailed}!void {
    switch (self.err) {
        .any => |e| try writer.print("{s} failed with {t}", .{ self.what, e }),
        .win32 => |e| try writer.print("{s} failed, error={f}", .{ self.what, e }),
    }
}

const std = @import("std");
const win32 = @import("win32").everything;
