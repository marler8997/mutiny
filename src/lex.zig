pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub fn extent(t: Token) Extent {
        return .{ .start = t.start, .end = t.end };
    }

    pub fn extentTrimmed(t: Token) Extent {
        return .{ .start = t.start + 1, .end = t.end - 1 };
    }

    pub fn fmt(t: Token, text: []const u8) TokenFmt {
        return .{ .token = t, .text = text };
    }

    pub const Tag = enum {
        invalid,
        identifier,
        string_literal,
        // char_literal,
        eof,
        builtin,
        @"!",
        // pipe,
        // pipe_pipe,
        @"=",
        @"==",
        @"!=",
        l_paren,
        r_paren,
        // percent,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        period,
        plus,
        minus,
        // colon,
        slash,
        comma,
        // ampersand,
        @"<",
        @"<=",
        @">",
        @">=",
        number_literal,
        keyword_break,
        keyword_continue,
        keyword_fn,
        keyword_if,
        keyword_new,
        keyword_set,
        keyword_var,
        keyword_loop,
    };
    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "break", .keyword_break },
        .{ "continue", .keyword_continue },
        .{ "fn", .keyword_fn },
        .{ "if", .keyword_if },
        .{ "loop", .keyword_loop },
        .{ "new", .keyword_new },
        .{ "set", .keyword_set },
        .{ "var", .keyword_var },
    });
    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }
};
const TokenFmt = struct {
    token: Token,
    text: []const u8,
    pub fn format(f: TokenFmt, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (f.token.tag) {
            .invalid => try writer.print("an invalid token '{s}'", .{f.text[f.token.start..f.token.end]}),
            .identifier => try writer.print("an identifer '{s}'", .{f.text[f.token.start..f.token.end]}),
            .string_literal => try writer.print("a string literal {s}", .{f.text[f.token.start..f.token.end]}),
            .eof => try writer.writeAll("EOF"),
            .builtin => try writer.print("the builtin function '{s}'", .{f.text[f.token.start..f.token.end]}),
            .@"!" => try writer.writeAll("a '!' operator"),
            .@"=" => try writer.writeAll("an equal '=' character"),
            .@"==" => try writer.writeAll("an '==' operator"),
            .@"!=" => try writer.writeAll("a '!=' operator"),
            .l_paren => try writer.writeAll("an open paren '('"),
            .r_paren => try writer.writeAll("a close paren ')'"),
            .l_brace => try writer.writeAll("an open brace '{'"),
            .r_brace => try writer.writeAll("a close brace '}'"),
            .l_bracket => try writer.writeAll("an open bracket '['"),
            .r_bracket => try writer.writeAll("a close bracket ']'"),
            .period => try writer.writeAll("a period '.'"),
            .plus => try writer.writeAll("a plus '+'"),
            .minus => try writer.writeAll("a minus '-'"),
            .slash => try writer.writeAll("a slash '/'"),
            .comma => try writer.writeAll("a comma ','"),
            .@"<" => try writer.writeAll("a less than '<' operator"),
            .@"<=" => try writer.writeAll("a less than or equal '<=' operator"),
            .@">" => try writer.writeAll("a greater than '>' operator"),
            .@">=" => try writer.writeAll("a greater than or equal '>=' operator"),
            .keyword_break => try writer.writeAll("the 'break' keyword"),
            .keyword_continue => try writer.writeAll("the 'continue' keyword"),
            .number_literal => try writer.print("a number literal {s}", .{f.text[f.token.start..f.token.end]}),
            .keyword_fn => try writer.writeAll("the 'fn' keyword"),
            .keyword_if => try writer.writeAll("the 'if' keyword"),
            .keyword_loop => try writer.writeAll("the 'loop' keyword"),
            .keyword_new => try writer.writeAll("the 'new' keyword"),
            .keyword_set => try writer.writeAll("the 'set' keyword"),
            .keyword_var => try writer.writeAll("the 'var' keyword"),
        }
    }
};

pub fn next(text: []const u8, lex_start: usize) Token {
    const State = union(enum) {
        start,
        identifier: usize,
        saw_at_sign: usize,
        builtin: usize,
        string_literal: usize,
        equal: usize,
        bang: usize,
        slash: usize,
        line_comment,
        int: usize,
        int_period: usize,
        float: usize,
        angle_bracket_left: usize,
        angle_bracket_right: usize,
    };

    var index = lex_start;
    var state: State = .start;

    while (true) {
        if (index >= text.len) return switch (state) {
            .start, .line_comment => .{ .tag = .eof, .start = index, .end = index },
            .identifier => |start| .{
                .tag = Token.getKeyword(text[start..index]) orelse .identifier,
                .start = start,
                .end = index,
            },
            .builtin => |start| .{ .tag = .builtin, .start = start, .end = index },
            .saw_at_sign, .string_literal => |start| .{ .tag = .invalid, .start = start, .end = index },
            .equal => |start| .{ .tag = .@"=", .start = start, .end = index },
            .bang => |start| .{ .tag = .@"!", .start = start, .end = index },
            .slash => |start| .{ .tag = .slash, .start = start, .end = index },
            .int, .float => |start| .{ .tag = .number_literal, .start = start, .end = index },
            .int_period => |start| .{ .tag = .number_literal, .start = start, .end = index - 1 },
            .angle_bracket_left => |start| .{ .tag = .@"<", .start = start, .end = index },
            .angle_bracket_right => |start| .{ .tag = .@">", .start = start, .end = index },
        };
        switch (state) {
            .start => {
                switch (text[index]) {
                    ' ', '\n', '\t', '\r' => index += 1,
                    '"' => {
                        state = .{ .string_literal = index };
                        index += 1;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .{ .identifier = index };
                        index += 1;
                    },
                    '@' => {
                        state = .{ .saw_at_sign = index };
                        index += 1;
                    },
                    '=' => {
                        state = .{ .equal = index };
                        index += 1;
                    },
                    '!' => {
                        state = .{ .bang = index };
                        index += 1;
                    },
                    // '|' => continue :state .pipe,
                    '(' => return .{ .tag = .l_paren, .start = index, .end = index + 1 },
                    ')' => return .{ .tag = .r_paren, .start = index, .end = index + 1 },
                    '[' => return .{ .tag = .l_bracket, .start = index, .end = index + 1 },
                    ']' => return .{ .tag = .r_bracket, .start = index, .end = index + 1 },
                    ',' => return .{ .tag = .comma, .start = index, .end = index + 1 },
                    // ':'
                    // '%'
                    // '*'
                    '+' => return .{ .tag = .plus, .start = index, .end = index + 1 },
                    '<' => {
                        state = .{ .angle_bracket_left = index };
                        index += 1;
                    },
                    '>' => {
                        state = .{ .angle_bracket_right = index };
                        index += 1;
                    },
                    // '^'
                    // '\\'
                    '{' => return .{ .tag = .l_brace, .start = index, .end = index + 1 },
                    '}' => return .{ .tag = .r_brace, .start = index, .end = index + 1 },
                    '.' => return .{ .tag = .period, .start = index, .end = index + 1 },
                    '-' => return .{ .tag = .minus, .start = index, .end = index + 1 },
                    '/' => {
                        state = .{ .slash = index };
                        index += 1;
                    },
                    // '&' => continue :state .ampersand,
                    '0'...'9' => {
                        state = .{ .int = index };
                        index += 1;
                    },
                    else => return .{ .tag = .invalid, .start = index, .end = index + 1 },
                }
            },
            .identifier => |start| {
                switch (text[index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => index += 1,
                    else => {
                        const string = text[start..index];
                        return .{ .tag = Token.getKeyword(string) orelse .identifier, .start = start, .end = index };
                    },
                }
            },
            .saw_at_sign => |start| {
                switch (text[index]) {
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .{ .builtin = start };
                        index += 1;
                    },
                    else => return .{ .tag = .invalid, .start = start, .end = index },
                }
            },
            .builtin => |start| switch (text[index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => index += 1,
                else => return .{ .tag = .builtin, .start = start, .end = index },
            },
            .string_literal => |start| switch (text[index]) {
                '"' => return .{ .tag = .string_literal, .start = start, .end = index + 1 },
                '\n' => return .{ .tag = .invalid, .start = start, .end = index },
                else => index += 1,
            },
            .equal => |start| switch (text[index]) {
                '=' => return .{ .tag = .@"==", .start = start, .end = index + 1 },
                else => return .{ .tag = .@"=", .start = start, .end = index },
            },
            .bang => |start| switch (text[index]) {
                '=' => return .{ .tag = .@"!=", .start = start, .end = index + 1 },
                else => return .{ .tag = .@"!", .start = start, .end = index },
            },
            .slash => |start| switch (text[index]) {
                '/' => {
                    state = .line_comment;
                    index += 1;
                },
                else => return .{ .tag = .slash, .start = start, .end = index },
            },
            .line_comment => switch (text[index]) {
                '\n' => {
                    state = .start;
                    index += 1;
                },
                else => index += 1,
            },
            .int => |start| switch (text[index]) {
                '.' => {
                    state = .{ .int_period = start };
                    index += 1;
                },
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    index += 1;
                },
                else => return .{ .tag = .number_literal, .start = start, .end = index },
            },
            .int_period => |start| switch (text[index]) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    state = .{ .float = start };
                    index += 1;
                },
                else => return .{ .tag = .number_literal, .start = start, .end = index - 1 },
            },
            .float => |start| switch (text[index]) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    index += 1;
                },
                else => return .{ .tag = .number_literal, .start = start, .end = index },
            },
            .angle_bracket_left => |start| switch (text[index]) {
                '=' => return .{ .tag = .@"<=", .start = start, .end = index + 1 },
                else => return .{ .tag = .@"<", .start = start, .end = index },
            },
            .angle_bracket_right => |start| switch (text[index]) {
                '=' => return .{ .tag = .@">=", .start = start, .end = index + 1 },
                else => return .{ .tag = .@">", .start = start, .end = index },
            },
        }
    }
}

const TokenIterator = struct {
    text: []const u8,
    offset: usize = 0,
    pub fn next(it: *TokenIterator) Token {
        const token = Lex.next(it.text, it.offset);
        it.offset = token.end;
        return token;
    }
    pub fn expect(it: *TokenIterator, tag: Token.Tag, str: []const u8) !void {
        const token = it.next();
        try std.testing.expectEqual(tag, token.tag);
        try std.testing.expectEqualSlices(u8, str, it.text[token.start..token.end]);
    }
};

test "lex" {
    {
        var it: TokenIterator = .{ .text = "" };
        try it.expect(.eof, "");
    }
    {
        var it: TokenIterator = .{ .text =
            \\cs = @Assembly("Assembly-CSharp")
            \\
            \\fn void ExecuteSprintCommand(bool fromServer, string[] args) {
            \\    print("test")
            \\}
            \\
            \\cmd = cs.DebugCommandHandler.ChatCommand(
            \\    "sprint",
            \\    ExecuteSprintCommand,
            \\    null,
            \\    false,
            \\)
            \\
        };
        try it.expect(.identifier, "cs");
        try it.expect(.@"=", "=");
        try it.expect(.builtin, "@Assembly");
        try it.expect(.l_paren, "(");
        try it.expect(.string_literal, "\"Assembly-CSharp\"");
        try it.expect(.r_paren, ")");
        try it.expect(.keyword_fn, "fn");
        try it.expect(.identifier, "void");
        try it.expect(.identifier, "ExecuteSprintCommand");
        try it.expect(.l_paren, "(");
        try it.expect(.identifier, "bool");
        try it.expect(.identifier, "fromServer");
        try it.expect(.comma, ",");
        try it.expect(.identifier, "string");
        try it.expect(.l_bracket, "[");
        try it.expect(.r_bracket, "]");
        try it.expect(.identifier, "args");
        try it.expect(.r_paren, ")");
        try it.expect(.l_brace, "{");
        try it.expect(.identifier, "print");
        try it.expect(.l_paren, "(");
        try it.expect(.string_literal, "\"test\"");
        try it.expect(.r_paren, ")");
        try it.expect(.r_brace, "}");
        try it.expect(.identifier, "cmd");
        try it.expect(.@"=", "=");
        try it.expect(.identifier, "cs");
        try it.expect(.period, ".");
        try it.expect(.identifier, "DebugCommandHandler");
        try it.expect(.period, ".");
        try it.expect(.identifier, "ChatCommand");
        try it.expect(.l_paren, "(");
        try it.expect(.string_literal, "\"sprint\"");
        try it.expect(.comma, ",");
        try it.expect(.identifier, "ExecuteSprintCommand");
        try it.expect(.comma, ",");
        try it.expect(.identifier, "null");
        try it.expect(.comma, ",");
        try it.expect(.identifier, "false");
        try it.expect(.comma, ",");
        try it.expect(.r_paren, ")");
    }
}

pub const Extent = struct { start: usize, end: usize };

pub fn lineNum(text: []const u8, offset: usize) u32 {
    var line_num: u32 = 1;
    for (text[0..@min(text.len, offset)]) |c| {
        if (c == '\n') line_num += 1;
    }
    return line_num;
}

const std = @import("std");

const Lex = @This();
