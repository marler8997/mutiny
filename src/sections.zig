pub const Hook = enum {
    update,
    disable,
};

pub const Section = struct {
    start: usize,
    end: usize,
    first_line: u32,
    pub fn text(section: Section, file_text: []const u8) []const u8 {
        return file_text[section.start..section.end];
    }
};

pub const Sections = std.EnumArray(Hook, ?Section);

pub const Error = union(enum) {
    unexpected_token: struct { expected: [:0]const u8, token: Token },
    nested: usize,
    code_outside_section: usize,
    unknown_section: Extent,
    duplicate_section: Extent,

    pub fn fmt(err: *const Error, text: []const u8) ErrorFmt {
        return .{ .err = err, .text = text };
    }
};

const ErrorFmt = struct {
    err: *const Error,
    text: []const u8,
    pub fn format(f: *const ErrorFmt, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (f.err.*) {
            .unexpected_token => |e| try writer.print(
                "{d}: syntax error: expected {s} but got {f}",
                .{ lex.lineNum(f.text, e.token.start), e.expected, e.token.fmt(f.text) },
            ),
            .nested => |pos| try writer.print(
                "{d}: @Section must be at the top level, not inside a block",
                .{lex.lineNum(f.text, pos)},
            ),
            .code_outside_section => |pos| try writer.print(
                "{d}: missing @Section",
                .{lex.lineNum(f.text, pos)},
            ),
            .unknown_section => |e| try writer.print(
                "{d}: unknown section '.{s}', expected one of {s}",
                .{ lex.lineNum(f.text, e.start), f.text[e.start..e.end], hook_names },
            ),
            .duplicate_section => |e| try writer.print(
                "{d}: duplicate @Section(.{s})",
                .{ lex.lineNum(f.text, e.start), f.text[e.start..e.end] },
            ),
        }
    }
};

const hook_names = blk: {
    var s: []const u8 = "";
    for (@typeInfo(Hook).@"enum".fields, 0..) |field, i| {
        s = s ++ (if (i == 0) "" else ", ") ++ "." ++ field.name;
    }
    break :blk s;
};

pub const Scan = union(enum) {
    sections: Sections,
    err: Error,
};

pub fn scan(text: []const u8) Scan {
    var scanner: Scanner = .{ .text = text };
    const sections = scanner.scan() catch return .{ .err = scanner.err };
    return .{ .sections = sections };
}

const Scanner = struct {
    text: []const u8,
    err: Error = undefined,

    fn fail(s: *Scanner, e: Error) error{Scan} {
        s.err = e;
        return error.Scan;
    }

    fn eatToken(s: *Scanner, start: usize, expected_tag: Token.Tag, expected: [:0]const u8) error{Scan}!usize {
        const t = lex.next(s.text, start);
        if (t.tag != expected_tag) return s.fail(.{
            .unexpected_token = .{ .expected = expected, .token = t },
        });
        return t.end;
    }

    fn scan(s: *Scanner) error{Scan}!Sections {
        var sections: Sections = .initFill(null);
        var open: ?Hook = null;
        var depth: usize = 0;
        var first_code: ?usize = null;
        var offset: usize = 0;
        while (true) {
            const token = lex.next(s.text, offset);
            if (token.tag == .eof) break;
            std.debug.assert(token.end > offset);
            offset = token.end;
            switch (token.tag) {
                .l_brace => depth += 1,
                .r_brace => depth -|= 1,
                .builtin => if (std.mem.eql(u8, s.text[token.start..token.end], "@Section")) {
                    if (depth != 0) return s.fail(.{ .nested = token.start });
                    if (open == null) if (first_code) |pos| return s.fail(.{ .code_outside_section = pos });
                    if (open) |hook| sections.getPtr(hook).*.?.end = token.start;
                    const after_lparen = try s.eatToken(token.end, .l_paren, "a '(' to start the @Section args");
                    const after_period = try s.eatToken(after_lparen, .period, "an enum literal naming the section");
                    const name_token = lex.next(s.text, after_period);
                    if (name_token.tag != .identifier) return s.fail(.{ .unexpected_token = .{
                        .expected = "an identifier after '.' naming the section",
                        .token = name_token,
                    } });
                    const after_rparen = try s.eatToken(name_token.end, .r_paren, "a ')' to end the @Section args");
                    const hook = std.meta.stringToEnum(Hook, s.text[name_token.start..name_token.end]) orelse return s.fail(.{
                        .unknown_section = name_token.extent(),
                    });
                    if (sections.get(hook) != null) return s.fail(.{ .duplicate_section = name_token.extent() });
                    sections.set(hook, .{
                        .start = after_rparen,
                        .end = s.text.len,
                        .first_line = lex.lineNum(s.text, after_rparen),
                    });
                    open = hook;
                    offset = after_rparen;
                    continue;
                },
                else => {},
            }
            if (first_code == null) first_code = token.start;
        }
        if (open == null) if (first_code) |pos| return s.fail(.{ .code_outside_section = pos });
        return sections;
    }
};

fn expectScan(text: []const u8, expected: []const struct { Hook, []const u8, u32 }) !void {
    const sections = switch (scan(text)) {
        .sections => |s| s,
        .err => |err| {
            std.debug.print("unexpected scan error: {f}\n", .{err.fmt(text)});
            return error.TestUnexpectedError;
        },
    };
    var seen: std.EnumSet(Hook) = .initEmpty();
    for (expected) |e| {
        const hook, const expected_text, const expected_line = e;
        seen.insert(hook);
        const section = sections.get(hook) orelse {
            std.debug.print("section .{t} missing\n", .{hook});
            return error.TestExpectedSection;
        };
        try std.testing.expectEqualStrings(expected_text, section.text(text));
        try std.testing.expectEqual(expected_line, section.first_line);
    }
    var it = seen.complement().iterator();
    while (it.next()) |hook| if (sections.get(hook) != null) {
        std.debug.print("section .{t} unexpectedly present\n", .{hook});
        return error.TestUnexpectedSection;
    };
}

fn expectScanError(text: []const u8, expected: []const u8) !void {
    switch (scan(text)) {
        .sections => return error.TestUnexpectedSuccess,
        .err => |err| {
            var buf: [512]u8 = undefined;
            const actual = try std.fmt.bufPrint(&buf, "{f}", .{err.fmt(text)});
            try std.testing.expectEqualStrings(expected, actual);
        },
    }
}

test "scan" {
    try expectScan("", &.{});
    try expectScan("// only a comment\n", &.{});
    try expectScan("@Section(.update)", &.{.{ .update, "", 1 }});
    try expectScan("// a comment\n@Section(.update)\n@Nothing()\n", &.{
        .{ .update, "\n@Nothing()\n", 2 },
    });
    try expectScan(
        \\@Section(.update)
        \\var x = 1
        \\if (x) { @Nothing() }
        \\@Section(.disable)
        \\set x = 0
    , &.{
        .{ .update, "\nvar x = 1\nif (x) { @Nothing() }\n", 1 },
        .{ .disable, "\nset x = 0", 4 },
    });
    try expectScan("@Section(.disable)\n@Section(.update)", &.{
        .{ .disable, "\n", 1 },
        .{ .update, "", 2 },
    });
    try expectScan("@Section(.disable) @Nothing()", &.{.{ .disable, " @Nothing()", 1 }});
    try expectScan("@Section(.update) \"@Section(.disable)\" // @Section(.enable)", &.{
        .{ .update, " \"@Section(.disable)\" // @Section(.enable)", 1 },
    });
}

test "scan errors" {
    try expectScanError("@Nothing()\n", "1: missing @Section");
    try expectScanError("\n\nvar x = 1\n@Nothing()\n@Section(.update)", "3: missing @Section");
    try expectScanError("@Section(.update)\nif (1) {\n@Section(.disable)\n}", "3: @Section must be at the top level, not inside a block");
    try expectScanError("@Section(.update)\n@Section(.update)", "2: duplicate @Section(.update)");
    try expectScanError("@Section(.tick)", "1: unknown section '.tick', expected one of .update, .disable");
    try expectScanError("@Section", "1: syntax error: expected a '(' to start the @Section args but got EOF");
    try expectScanError("@Section(update)", "1: syntax error: expected an enum literal naming the section but got an identifer 'update'");
    try expectScanError("@Section(.\"update\")", "1: syntax error: expected an identifier after '.' naming the section but got a string literal \"update\"");
    try expectScanError("@Section(.update", "1: syntax error: expected a ')' to end the @Section args but got EOF");
}

const std = @import("std");

const lex = @import("lex.zig");

const Token = lex.Token;
const Extent = lex.Extent;
