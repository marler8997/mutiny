const ModFile = @This();

list_node: std.DoublyLinkedList.Node,

name: BoundedArray(u8, ModNameSlice.max_len),
stale: bool,
last: union(enum) {
    initial,
    text: struct { hash: u64, len: usize },
    err: ErrorNoText,
},

pub const ErrorNoText = union(enum) {
    open_file: std.fs.File.OpenError,
    file_size: std.fs.File.GetEndPosError,
    file_too_big: u64,
    out_of_memory,
    read_file: (error{EndOfStream} || std.fs.File.ReadError),
    pub fn eql(self: ErrorNoText, other: ErrorNoText) bool {
        return (std.meta.activeTag(self) == std.meta.activeTag(other)) and switch (self) {
            .open_file => |e| e == other.open_file,
            .file_size => |e| e == other.file_size,
            .file_too_big => |e| e == other.file_too_big,
            .out_of_memory => true,
            .read_file => |e| e == other.read_file,
        };
    }
    pub fn log(err: ErrorNoText, mod_name: []const u8) void {
        switch (err) {
            .open_file => |e| std.log.err("open mod file '{s}' failed with {t}", .{ mod_name, e }),
            .file_size => |e| std.log.err("get size of mod file '{s}' failed with {t}", .{ mod_name, e }),
            .file_too_big => |size| std.log.err("mod file '{s}' is too big ({} bytes)", .{ mod_name, size }),
            .out_of_memory => std.log.err("out of memory reading mod file '{s}'", .{mod_name}),
            .read_file => |e| std.log.err("read mod file '{s}' failed with {t}", .{ mod_name, e }),
        }
    }
};

pub fn nameSlice(file: *const ModFile) ModNameSlice {
    return .{ .ptr = &file.name.buffer, .len = file.name.len };
}

const std = @import("std");

const mainthread = @import("mainthread");

const BoundedArray = mainthread.BoundedArray;
const ModNameSlice = mainthread.ModNameSlice;
