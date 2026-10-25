pub const KeyCode = enum(i32) {
    none = 0,
    escape = 27,
    _,

    pub const max_name_len = "KeyCode -2147483648".len;

    pub fn format(key: KeyCode, writer: *std.Io.Writer) error{WriteFailed}!void {
        const code = @intFromEnum(key);
        if (name(code)) |n| return writer.writeAll(n);
        switch (code) {
            '!'...'~' => try writer.writeByte(std.ascii.toUpper(@intCast(code))),
            256...265 => try writer.print("Keypad{d}", .{code - 256}),
            282...296 => try writer.print("F{d}", .{code - 281}),
            else => try writer.print("KeyCode {d}", .{code}),
        }
    }
};

fn name(code: i32) ?[:0]const u8 {
    return switch (code) {
        8 => "Backspace",
        9 => "Tab",
        12 => "Clear",
        13 => "Return",
        19 => "Pause",
        27 => "Escape",
        32 => "Space",
        127 => "Delete",
        266 => "KeypadPeriod",
        267 => "KeypadDivide",
        268 => "KeypadMultiply",
        269 => "KeypadMinus",
        270 => "KeypadPlus",
        271 => "KeypadEnter",
        272 => "KeypadEquals",
        273 => "UpArrow",
        274 => "DownArrow",
        275 => "RightArrow",
        276 => "LeftArrow",
        277 => "Insert",
        278 => "Home",
        279 => "End",
        280 => "PageUp",
        281 => "PageDown",
        300 => "Numlock",
        301 => "CapsLock",
        302 => "ScrollLock",
        303 => "RightShift",
        304 => "LeftShift",
        305 => "RightControl",
        306 => "LeftControl",
        307 => "RightAlt",
        308 => "LeftAlt",
        309 => "RightMeta",
        310 => "LeftMeta",
        311 => "LeftWindows",
        312 => "RightWindows",
        313 => "AltGr",
        315 => "Help",
        316 => "Print",
        317 => "SysReq",
        318 => "Break",
        319 => "Menu",
        else => null,
    };
}

fn expectName(key: KeyCode, expected: []const u8) !void {
    var buf: [KeyCode.max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{key}));
}

test "max_name_len" {
    var max = std.fmt.count("{f}", .{@as(KeyCode, @enumFromInt(std.math.minInt(i32)))});
    for (0..400) |code| max = @max(max, std.fmt.count("{f}", .{@as(KeyCode, @enumFromInt(code))}));
    try std.testing.expectEqual(max, KeyCode.max_name_len);
}

test "format" {
    try expectName(@enumFromInt(std.math.minInt(i32)), "KeyCode -2147483648");
    try expectName(@enumFromInt(289), "F8");
    try expectName(@enumFromInt('a'), "A");
    try expectName(@enumFromInt('5'), "5");
    try expectName(@enumFromInt('`'), "`");
    try expectName(@enumFromInt(32), "Space");
    try expectName(@enumFromInt(258), "Keypad2");
    try expectName(@enumFromInt(273), "UpArrow");
    try expectName(@enumFromInt(304), "LeftShift");
    try expectName(@enumFromInt(312), "RightWindows");
    try expectName(@enumFromInt(296), "F15");
    try expectName(@enumFromInt(5000), "KeyCode 5000");
}

const std = @import("std");
