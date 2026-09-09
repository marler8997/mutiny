const Mod = @This();

list_node: std.DoublyLinkedList.Node,
name: BoundedArray(u8, ModNameSlice.max_len),
text: []u8,
scan: sections.Scan,
state: State,
label: unitygui.ModLabel,

pub const status_max_len = std.math.maxInt(u8);
pub const Status = BoundedArray(u8, status_max_len);

pub const State = union(enum) {
    off,
    stopping,
    on: Outcome,
};

pub const Outcome = union(enum) {
    not_run,
    ok,
    result: Status,
    err: Status,

    pub fn eql(a: *const Outcome, b: *const Outcome) bool {
        return switch (a.*) {
            .not_run => b.* == .not_run,
            .ok => b.* == .ok,
            .result => |*a_status| b.* == .result and std.mem.eql(u8, a_status.slice(), b.result.slice()),
            .err => |*a_status| b.* == .err and std.mem.eql(u8, a_status.slice(), b.err.slice()),
        };
    }
};

pub const StatusText = struct { kind: enum { disabled, ok, err }, text: []const u8 };

pub fn create(name: BoundedArray(u8, ModNameSlice.max_len), text: []u8) error{OutOfMemory}!*Mod {
    const mod = try alloc.newMod();
    mod.* = .{
        .list_node = .{},
        .name = name,
        .text = text,
        .scan = sections.scan(text),
        .state = .{ .on = .not_run },
        .label = .{},
    };
    return mod;
}

pub fn enabled(mod: *const Mod) bool {
    return mod.state == .on;
}

pub fn setEnabled(mod: *Mod, enable: bool) enum { changed, unchanged } {
    switch (mod.state) {
        .on => |outcome| {
            if (enable) return .unchanged;
            mod.state = if (outcome == .not_run) .off else .stopping;
        },
        .off, .stopping => {
            if (!enable) return .unchanged;
            mod.state = .{ .on = .not_run };
        },
    }
    return .changed;
}

pub fn statusText(mod: *const Mod) StatusText {
    return switch (mod.state) {
        .off => .{ .kind = .disabled, .text = "disabled" },
        .stopping => .{ .kind = .disabled, .text = "disabling" },
        .on => |*outcome| switch (outcome.*) {
            .not_run, .ok => .{ .kind = .ok, .text = "enabled" },
            .result => |*status| .{ .kind = .ok, .text = status.slice() },
            .err => |*status| .{ .kind = .err, .text = status.slice() },
        },
    };
}

pub fn formatInto(status: *Status, comptime fmt: []const u8, args: anytype) void {
    const ellipsis = "...";
    const text = std.fmt.bufPrint(status.buffer[0 .. status_max_len - ellipsis.len], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => truncated: {
            @memcpy(status.buffer[status_max_len - ellipsis.len ..], ellipsis);
            break :truncated status.buffer[0..];
        },
    };
    status.len = @intCast(text.len);
}

pub fn destroy(mod: *Mod, dotnet_funcs: *const dotnet.Funcs) void {
    mod.label.deinit(dotnet_funcs);
    alloc.general().free(mod.text);
    mod.* = undefined;
    alloc.freeMod(mod);
}

const std = @import("std");
const mutiny = @import("mutiny");
const dotnet = mutiny.dotnet;
const sections = mutiny.sections;

const alloc = @import("alloc.zig");
const unitygui = @import("unitygui.zig");

const BoundedArray = mutiny.BoundedArray;
const ModNameSlice = @import("ModNameSlice.zig");
