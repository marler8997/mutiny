const PanelToggle = @This();

state: State = .unbound,

pub const State = union(enum) {
    unbound,
    binding: Binding,
    bound: Bound,
};

pub const Binding = struct {
    previous: ?KeyCode,
};

pub const Bound = struct {
    key: KeyCode,
    hidden: bool,
    held: bool,
};

pub const Handled = enum { ignored, consumed };

pub fn hidden(toggle: *const PanelToggle) bool {
    return switch (toggle.state) {
        .unbound, .binding => false,
        .bound => |bound| bound.hidden,
    };
}

pub fn clickBind(toggle: *PanelToggle) void {
    const previous: ?KeyCode = switch (toggle.state) {
        .unbound => null,
        .binding => |binding| binding.previous,
        .bound => |bound| bound.key,
    };
    toggle.state = .{ .binding = .{ .previous = previous } };
}

pub fn keyDown(toggle: *PanelToggle, key: KeyCode) Handled {
    if (key == .none) return .ignored;
    switch (toggle.state) {
        .unbound => return .ignored,
        .binding => |binding| {
            const previous_key = binding.previous;
            toggle.state = if (key != .escape)
                .{ .bound = .{ .key = key, .hidden = false, .held = true } }
            else if (previous_key) |previous|
                .{ .bound = .{ .key = previous, .hidden = false, .held = false } }
            else
                .unbound;
            return .consumed;
        },
        .bound => |*bound| {
            if (bound.key != key) return .ignored;
            if (!bound.held) {
                bound.hidden = !bound.hidden;
                bound.held = true;
            }
            return .consumed;
        },
    }
}

pub fn keyUp(toggle: *PanelToggle, key: KeyCode) Handled {
    switch (toggle.state) {
        .unbound, .binding => return .ignored,
        .bound => |*bound| {
            if (bound.key != key) return .ignored;
            bound.held = false;
            return .consumed;
        },
    }
}

const f8: KeyCode = @enumFromInt(289);
const a: KeyCode = @enumFromInt('a');

fn boundState(key: KeyCode, is_hidden: bool, held: bool) State {
    return .{ .bound = .{ .key = key, .hidden = is_hidden, .held = held } };
}

test "nothing is bound until the bind button is clicked" {
    var toggle: PanelToggle = .{};
    try std.testing.expectEqual(.ignored, toggle.keyDown(f8));
    try std.testing.expectEqual(.ignored, toggle.keyUp(f8));
    try std.testing.expectEqual(.unbound, toggle.state);
    try std.testing.expectEqual(false, toggle.hidden());
}

test "the next key after the bind button is bound, and toggles once per press" {
    var toggle: PanelToggle = .{};
    toggle.clickBind();
    try std.testing.expectEqual(State{ .binding = .{ .previous = null } }, toggle.state);
    try std.testing.expectEqual(.consumed, toggle.keyDown(f8));
    try std.testing.expectEqual(boundState(f8, false, true), toggle.state);

    try std.testing.expectEqual(.consumed, toggle.keyDown(f8));
    try std.testing.expectEqual(boundState(f8, false, true), toggle.state);
    try std.testing.expectEqual(.consumed, toggle.keyUp(f8));
    try std.testing.expectEqual(boundState(f8, false, false), toggle.state);

    try std.testing.expectEqual(.consumed, toggle.keyDown(f8));
    try std.testing.expectEqual(boundState(f8, true, true), toggle.state);
    try std.testing.expectEqual(true, toggle.hidden());
    try std.testing.expectEqual(.consumed, toggle.keyDown(f8));
    try std.testing.expectEqual(boundState(f8, true, true), toggle.state);
    try std.testing.expectEqual(.consumed, toggle.keyUp(f8));

    try std.testing.expectEqual(.consumed, toggle.keyDown(f8));
    try std.testing.expectEqual(boundState(f8, false, true), toggle.state);
}

test "other keys and the character event's none pass through" {
    var toggle: PanelToggle = .{};
    toggle.clickBind();
    try std.testing.expectEqual(.ignored, toggle.keyDown(.none));
    try std.testing.expectEqual(State{ .binding = .{ .previous = null } }, toggle.state);
    _ = toggle.keyDown(f8);
    _ = toggle.keyUp(f8);
    try std.testing.expectEqual(.ignored, toggle.keyDown(a));
    try std.testing.expectEqual(.ignored, toggle.keyUp(a));
    try std.testing.expectEqual(.ignored, toggle.keyDown(.none));
    try std.testing.expectEqual(.ignored, toggle.keyUp(.none));
    try std.testing.expectEqual(boundState(f8, false, false), toggle.state);
}

test "escape cancels binding and keeps the old key" {
    var toggle: PanelToggle = .{};
    toggle.clickBind();
    try std.testing.expectEqual(.consumed, toggle.keyDown(.escape));
    try std.testing.expectEqual(.unbound, toggle.state);

    toggle.clickBind();
    _ = toggle.keyDown(f8);
    _ = toggle.keyUp(f8);
    toggle.clickBind();
    try std.testing.expectEqual(State{ .binding = .{ .previous = f8 } }, toggle.state);
    try std.testing.expectEqual(.consumed, toggle.keyDown(.escape));
    try std.testing.expectEqual(boundState(f8, false, false), toggle.state);
}

test "rebinding replaces the key, and the old key is just a key" {
    var toggle: PanelToggle = .{};
    toggle.clickBind();
    _ = toggle.keyDown(f8);
    _ = toggle.keyUp(f8);
    toggle.clickBind();
    try std.testing.expectEqual(.consumed, toggle.keyDown(a));
    try std.testing.expectEqual(.consumed, toggle.keyUp(a));
    try std.testing.expectEqual(.ignored, toggle.keyDown(f8));
    try std.testing.expectEqual(.consumed, toggle.keyDown(a));
    try std.testing.expectEqual(boundState(a, true, true), toggle.state);
}

const std = @import("std");
const KeyCode = @import("keys.zig").KeyCode;
