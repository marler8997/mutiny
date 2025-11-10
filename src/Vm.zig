const Vm = @This();

mono_funcs: *const mono.Funcs,
error_result: ErrorResult = undefined,
text: []const u8,
mem: Memory,

symbol_state: union(enum) {
    none,
    evaluating: struct {
        maybe_previous_newest: ?Memory.Addr,
        next_newest: Memory.Addr,
    },
    stable: struct {
        newest: Memory.Addr,
        next: Memory.Addr,
    },
} = .none,

tests_scheduled: bool = false,

const ErrorResult = union(enum) {
    exit,
    err: Error,
};

fn setError(vm: *Vm, e: Error) error{Vm} {
    vm.error_result = .{ .err = e };
    return error.Vm;
}

const Extent = struct { start: usize, end: usize };

const ReturnStorage = struct {
    type: ?Type = null,
    value: union {
        integer: i64,
        offset: usize,
        pointer: *anyopaque,
    } = undefined,
};

const Type = enum {
    integer,
    string_literal,
    // c_string,
    managed_string,
    script_function,
    assembly,
    assembly_field,
    class,
    class_member,
    object,
    pub fn what(t: Type) []const u8 {
        return switch (t) {
            .integer => "an integer",
            .string_literal => "a string literal",
            // .c_string => "a string",
            .managed_string => "a managed string",
            .script_function => "a function",
            .assembly => "an assembly",
            .assembly_field => "an assembly field",
            .class => "a class",
            .class_member => "a class member",
            .object => "an object",
        };
    }
    pub fn canMarshal(t: Type) bool {
        return switch (t) {
            .integer => true,
            .string_literal => true,
            // .c_string => true,
            .managed_string => true,
            // to send a function like a callback, I think we'll want some
            // sort of @CompileFunction() builtin or something so we
            // can store/save the data required on the stack
            .script_function => false,
            .assembly => false, // not sure if this should work or not
            .assembly_field => false, // not sure if this should work or not
            .class => false, // TODO
            .class_member => false, // TODO
            .object => false, // TODO
        };
    }
};

const TypeContext = enum { @"return", param };

fn getLineNum(text: []const u8, offset: usize) u32 {
    var line_num: u32 = 1;
    for (text[0..@min(text.len, offset)]) |c| {
        if (c == '\n') line_num += 1;
    }
    return line_num;
}

pub fn deinit(vm: *Vm) void {
    const maybe_id_addr: ?Memory.Addr = blk: switch (vm.symbol_state) {
        .none => {
            vm.discardValues(.zero);
            _ = vm.mem.discardFrom(.zero);
            break :blk null;
        },
        .evaluating => |e| {
            const maybe_previous = vm.discardTopSymbol(e.next_newest);
            if (maybe_previous) |p|
                std.debug.assert(p.eql(e.maybe_previous_newest.?))
            else
                std.debug.assert(e.maybe_previous_newest == null);
            break :blk e.maybe_previous_newest;
        },
        .stable => |s| break :blk vm.discardTopSymbol(s.newest),
    };
    var id_addr = maybe_id_addr orelse {
        std.debug.assert(vm.mem.top().eql(.zero));
        vm.mem.deinit();
        vm.* = undefined;
        return;
    };
    while (true) {
        const id_start, const after_id_addr = vm.readValue(usize, id_addr);
        const id = lex(vm.text, id_start);
        std.debug.assert(id.tag == .identifier);
        var previous_id_addr: Memory.Addr = undefined;
        var type_addr: Memory.Addr = undefined;
        if (id_addr.eql(.zero)) {
            type_addr = after_id_addr;
        } else {
            previous_id_addr, type_addr = vm.readValue(Memory.Addr, after_id_addr);
        }
        var value = vm.pop(type_addr);
        value.discard(vm.mono_funcs);
        _ = vm.mem.discardFrom(id_addr);
        if (id_addr.eql(.zero)) break;
        id_addr = previous_id_addr;
    }
    vm.mem.deinit();
    vm.* = undefined;
}

fn discardTopSymbol(vm: *Vm, addr: Memory.Addr) ?Memory.Addr {
    const id_start, const after_id_addr = vm.readValue(usize, addr);
    const id = lex(vm.text, id_start);
    std.debug.assert(id.tag == .identifier);
    var previous_id_addr: ?Memory.Addr = null;
    var type_addr: Memory.Addr = undefined;
    if (addr.eql(.zero)) {
        type_addr = after_id_addr;
    } else {
        previous_id_addr, type_addr = vm.readValue(Memory.Addr, after_id_addr);
    }
    vm.discardValues(type_addr);
    _ = vm.mem.discardFrom(addr);
    return previous_id_addr;
}

fn discardValues(vm: *Vm, first_type_addr: Memory.Addr) void {
    var type_addr = first_type_addr;
    while (!type_addr.eql(vm.mem.top())) {
        const value_type, const value_addr = vm.readValue(Type, type_addr);
        // seems like we need to handle this case?
        // if (value_addr.eql(vm.mem.top())) return;
        std.debug.assert(!value_addr.eql(vm.mem.top()));
        var value, const after_value = vm.readAnyValue(value_type, value_addr);
        value.discard(vm.mono_funcs);
        type_addr = after_value;
    }
}

fn logStack(vm: *Vm) void {
    const maybe_newest_symbol_addr: ?Memory.Addr = switch (vm.symbol_state) {
        .none => null,
        .evaluating => |e| e.next_newest,
        .stable => |s| s.next,
    };
    std.debug.print("STACK: top={f}\n", .{vm.mem.top()});
    std.debug.print("------------------------------\n", .{});
    defer std.debug.print("------------------------------\n", .{});
    var next_addr: Memory.Addr = .zero;
    if (maybe_newest_symbol_addr) |newest_symbol_addr| {
        while (true) {
            const is_newest = next_addr.eql(newest_symbol_addr);
            if (next_addr.eql(vm.mem.top())) break;
            const id_addr = next_addr;
            const id_start, next_addr = vm.readValue(usize, id_addr);
            const id = lex(vm.text, id_start);
            std.debug.assert(id.tag == .identifier);
            const id_text = vm.text[id.start..id.end];
            std.debug.print("{f}: symbol '{s}'\n", .{ id_addr, id_text });
            if (next_addr.eql(vm.mem.top())) break;
            if (!id_addr.eql(.zero)) {
                const previous_id_addr_addr = next_addr;
                const previous_id_addr, next_addr = vm.readValue(Memory.Addr, previous_id_addr_addr);
                std.debug.print("{f}: previous symbol addr {f}\n", .{ previous_id_addr_addr, previous_id_addr });
                if (next_addr.eql(vm.mem.top())) break;
            }
            const value_type_addr = next_addr;
            const value_type, next_addr = vm.readValue(Type, value_type_addr);
            std.debug.print("{f}: type '{t}'\n", .{ value_type_addr, value_type });
            if (next_addr.eql(vm.mem.top())) break;
            const value_addr = next_addr;
            const value, next_addr = vm.readAnyValue(value_type, value_addr);
            std.debug.print("{f}: value '{}'\n", .{ value_addr, value });
            if (next_addr.eql(vm.mem.top())) break;
            if (is_newest) break;
        }
    }
    while (!next_addr.eql(vm.mem.top())) {
        const value_type_addr = next_addr;
        const value_type, next_addr = vm.readValue(Type, value_type_addr);
        std.debug.print("{f}: type '{t}'\n", .{ value_type_addr, value_type });
        if (next_addr.eql(vm.mem.top())) break;
        const value_addr = next_addr;
        const value, next_addr = vm.readAnyValue(value_type, value_addr);
        std.debug.print("{f}: value '{}'\n", .{ value_addr, value });
        if (next_addr.eql(vm.mem.top())) break;
    }
    std.debug.print("{f}: (end of stack)\n", .{vm.mem.top()});
}

fn startSymbol(vm: *Vm, id_start: usize) error{Vm}!void {
    {
        const token = lex(vm.text, id_start);
        std.debug.assert(token.tag == .identifier);
        std.debug.assert(token.start == id_start);
    }

    const new_addr: Memory.Addr, const previous_newest: ?Memory.Addr = switch (vm.symbol_state) {
        .none => .{ .zero, null },
        .evaluating => unreachable,
        .stable => |*symbol_addrs| .{ symbol_addrs.next, symbol_addrs.newest },
    };
    std.debug.assert(vm.mem.top().eql(new_addr));
    (try vm.push(usize)).* = id_start;
    if (previous_newest) |p| (try vm.push(Memory.Addr)).* = p;
    vm.symbol_state = .{ .evaluating = .{
        .maybe_previous_newest = previous_newest,
        .next_newest = new_addr,
    } };
}
fn endSymbol(vm: *Vm) error{Vm}!void {
    const evaluating = switch (vm.symbol_state) {
        .none => unreachable,
        .evaluating => |*e| e,
        .stable => unreachable,
    };
    const next = vm.mem.top();
    std.debug.assert(!evaluating.next_newest.eql(next));
    vm.symbol_state = .{ .stable = .{
        .newest = evaluating.next_newest,
        .next = next,
    } };
}

pub fn verifyStack(vm: *Vm) void {
    // TODO: implement this
    _ = vm;
    // if (vm.symbols.first == null) {
    //     std.debug.assert(vm.mem.top().eql(.zero));
    //     return;
    // }

    // const first_symbol: *Symbol = @fieldParentPtr("list_node", vm.symbols.first.?);
    // var symbol = first_symbol;
    // while (true) {
    //     std.debug.print(
    //         "symbol '{s}' adddress {f}\n",
    //         .{
    //             vm.text[symbol.extent.start..symbol.extent.end],
    //             symbol.value_addr,
    //         },
    //     );
    //     // TODO: verify the value is valid
    //     _, _ = vm.readValue(Type, symbol.value_addr);
    //     const next = symbol.list_node.next orelse break;
    //     symbol = @fieldParentPtr("list_node", next);
    // }
}

const ManagedId = struct {
    buf: [max + 1]u8,
    len: std.math.IntFittingRange(0, max),

    // C# limits identifiers to 1023 characters (class names, method names, variables etc).
    const max = 1023;

    pub fn empty() ManagedId {
        var result: ManagedId = .{ .buf = undefined, .len = 0 };
        result.buf[0] = 0;
        return result;
    }

    pub fn slice(self: *const ManagedId) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    pub fn append(self: *ManagedId, s: []const u8) error{NoSpaceLeft}!void {
        if (self.len + s.len > max) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.buf[self.len + s.len] = 0;
        self.len += @intCast(s.len);
    }
};

pub const BlockResume = struct {
    text_offset: usize = 0,
    loop_text_offset: ?usize = null,
};

pub const Yield = struct {
    millis: i64,
    block_resume: BlockResume,
};

pub fn evalRoot(vm: *Vm, block_resume: BlockResume) error{Vm}!Yield {
    // std.debug.assert(vm.mem.top().eql(.zero));
    var next_statement_offset: usize = block_resume.text_offset;
    var loop_text_offset: ?usize = block_resume.loop_text_offset;
    _ = &loop_text_offset;
    while (true) {
        std.debug.assert(next_statement_offset <= vm.text.len);
        const new_offset = blk: switch (try vm.evalStatement(next_statement_offset, &loop_text_offset)) {
            .not_statement => |token| {
                if (token.tag == .eof) {
                    vm.error_result = .exit;
                    return error.Vm;
                }
                return vm.setError(.{ .unexpected_token = .{
                    .expected = "a statement",
                    .token = token,
                } });
            },
            .statement_end => |end| {
                std.debug.assert(end > next_statement_offset);
                break :blk end;
            },
            .yield => |yield| return yield,
            .@"continue" => |continue_pos| {
                const new_offset = loop_text_offset orelse return vm.setError(.{ .static_error = .{
                    .pos = continue_pos,
                    .string = "continue must correspond to a loop",
                } });
                std.debug.assert(new_offset < next_statement_offset);
                break :blk loop_text_offset.?;
            },
            .direct_break_no_loop => |after_break| {
                std.debug.assert(loop_text_offset == null);
                return vm.setError(.{ .static_error = .{
                    .pos = after_break - "break".len,
                    .string = "break must correspond to a loop",
                } });
            },
            .child_block_break => |child_block| {
                if (loop_text_offset == null) return vm.setError(.{ .static_error = .{
                    .pos = child_block.break_pos,
                    .string = "break must correspond to a loop",
                } });
                // find the end of the loop (break, continue or EOF)
                var offset: usize = child_block.end;
                _ = &offset;
                while (true) switch (try vm.eat().evalStatement(offset)) {
                    .not_statement => break :blk offset,
                    .statement_end => |end| offset = end,
                    .loop_escape => |end| break :blk end,
                };
            },
        };
        std.debug.assert(new_offset != next_statement_offset);
        next_statement_offset = new_offset;
    }
}

pub fn evalFunction(
    vm: *Vm,
    start: usize,
    return_storage: *ReturnStorage,
    args_addr: Memory.Addr,
) error{Vm}!usize {
    const body_start = blk: {
        const token = lex(vm.text, start);
        if (token.tag != .l_brace) return vm.setError(.{ .unexpected_token = .{
            .expected = "an open brace '{' to start function body",
            .token = token,
        } });
        break :blk token.end;
    };

    var loop_text_offset: ?usize = null;
    _ = &loop_text_offset;

    const after_close_brace = blk: {
        var offset: usize = body_start;
        while (true) {
            const new_offset = switch (try vm.evalStatement(offset, &loop_text_offset)) {
                .not_statement => |token| {
                    if (token.tag == .r_brace) break :blk token.end;
                    return vm.setError(.{ .unexpected_token = .{
                        .expected = "a statement",
                        .token = token,
                    } });
                },
                .statement_end => |end| {
                    std.debug.assert(end > offset);
                    break :blk end;
                },
                .yield => return vm.setError(.{ .static_error = .{
                    .pos = lex(vm.text, offset).start,
                    .string = "yield unsupported inside a function",
                } }),
                .@"continue" => {
                    std.debug.assert(loop_text_offset.? < offset);
                    break :blk loop_text_offset.?;
                },
                .direct_break_no_loop => @panic("todo"),
                .child_block_break => @panic("todo"),
            };
            std.debug.assert(new_offset != offset);
            offset = new_offset;
        }
    };

    _ = return_storage;
    if (!args_addr.eql(vm.mem.top())) return vm.setError(.{ .not_implemented = "evalFunction stack cleanup" });
    return after_close_brace;
}

const BlockBreak = struct {
    break_pos: usize,
    end: usize,
};

pub fn evalBlock(vm: *Vm, start: usize, comptime kind: enum { @"if" }) error{Vm}!union(enum) {
    complete: usize, // end of the block
    break_parent: BlockBreak,
    continue_parent: usize,
} {
    const body_start = blk: {
        const token = lex(vm.text, start);
        if (token.tag != .l_brace) return vm.setError(.{ .unexpected_token = .{
            .expected = "an open brace '{' to start " ++ @tagName(kind) ++ " block",
            .token = token,
        } });
        break :blk token.end;
    };

    var loop_text_offset: ?usize = null;

    // const eat_start = eat_remaining_block: {
    var offset: usize = body_start;
    while (true) {
        const new_offset = blk: switch (try vm.evalStatement(offset, &loop_text_offset)) {
            .not_statement => |token| {
                if (token.tag == .r_brace) return .{ .complete = token.end };
                return vm.setError(.{ .unexpected_token = .{
                    .expected = "a statement",
                    .token = token,
                } });
            },
            .statement_end => |end| {
                std.debug.assert(end > offset);
                break :blk end;
            },
            .yield => return vm.setError(.{
                .not_implemented = "yield inside a " ++ @tagName(kind) ++ " block",
            }),
            .@"continue" => |continue_pos| {
                if (loop_text_offset) |o| break :blk o;
                return .{ .continue_parent = continue_pos };
            },
            .direct_break_no_loop => |after_break| {
                std.debug.assert(loop_text_offset == null);
                return .{ .break_parent = .{
                    .break_pos = after_break - "break".len,
                    .end = try vm.eat().remainingBlock(after_break),
                } };
            },
            .child_block_break => |after_child_block| {
                _ = after_child_block;
                @panic("todo");
                // const after_r_brace = try vm.eat().remainingBlock(break_end);
                // if (loop_text_offset) |_| return .{ .complete = after_r_brace };
                // return .{ .break_parent = after_r_brace };
            },
        };
        std.debug.assert(new_offset != offset);
        offset = new_offset;
    }
    // };

}

fn evalStatement(vm: *Vm, start: usize, maybe_loop_ref: *?usize) error{Vm}!union(enum) {
    not_statement: Token,
    statement_end: usize,
    yield: Yield,
    @"continue": usize,
    direct_break_no_loop: usize,
    child_block_break: BlockBreak,
} {
    const first_token = lex(vm.text, start);
    switch (first_token.tag) {
        .identifier => {
            const second_token = lex(vm.text, first_token.end);
            if (second_token.tag == .@"=") {
                const entry = vm.lookup(vm.text[first_token.start..first_token.end]) orelse return vm.setError(.{
                    .undefined_identifier = first_token.extent(),
                });
                const symbol_type, const symbol_value_addr = vm.readValue(Type, entry.type_addr);
                const value_addr = vm.mem.top();
                const expr_first_token = lex(vm.text, second_token.end);
                const after_expr = try vm.evalExpr(expr_first_token) orelse return vm.setError(.{ .unexpected_token = .{
                    .expected = "an expresson to follow '='",
                    .token = expr_first_token,
                } });
                if (value_addr.eql(vm.mem.top())) return vm.setError(.{ .void_assignment = .{
                    .id_extent = first_token.extent(),
                } });
                const src = vm.pop(value_addr);
                if (src.getType() != symbol_type) return vm.setError(.{ .assign_type = .{
                    .id_extent = first_token.extent(),
                    .dst = symbol_type,
                    .src = src.getType(),
                } });
                switch (src) {
                    .integer => |value| vm.mem.toPointer(i64, symbol_value_addr).* = value,
                    else => @panic("todo: overwrite the value"),
                }
                return .{ .statement_end = after_expr };
            }
        },
        .keyword_fn => {
            const id_extent = blk: {
                const token = lex(vm.text, first_token.end);
                if (token.tag != .identifier) return vm.setError(.{ .unexpected_token = .{
                    .expected = "an identifier after 'fn'",
                    .token = token,
                } });
                break :blk token.extent();
            };
            const arg_start = blk: {
                const token = lex(vm.text, id_extent.end);
                if (token.tag != .l_paren) return vm.setError(.{ .unexpected_token = .{
                    .expected = "an open paren '(' to start function args",
                    .token = token,
                } });
                break :blk token.end;
            };
            const params = try vm.eat().evalParamDeclList(arg_start);
            const after_definition = try vm.eat().evalBlock(params.end, .function);

            try vm.startSymbol(id_extent.start);
            (try vm.push(Type)).* = .script_function;
            (try vm.push(usize)).* = arg_start;
            try vm.endSymbol();
            return .{ .statement_end = after_definition };
        },
        .keyword_if => {
            const after_lparen = try vm.eat().eatToken(
                first_token.end,
                .l_paren,
                "a '(' to start the if conditional",
            );
            const expr_addr = vm.mem.top();
            const first_expr_token = lex(vm.text, after_lparen);
            const after_expr = try vm.evalExpr(first_expr_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expression inside the if conditional",
                .token = first_expr_token,
            } });
            const after_rparen = try vm.eat().eatToken(
                after_expr,
                .r_paren,
                "a ')' to finish the if conditional",
            );
            if (expr_addr.eql(vm.mem.top())) return vm.setError(.{ .if_type = .{
                .pos = first_expr_token.start,
                .type = null,
            } });
            const is_true = blk: {
                var value = vm.pop(expr_addr);
                defer value.discard(vm.mono_funcs);
                break :blk switch (value) {
                    .integer => |int_value| int_value != 0,
                    else => |t| return vm.setError(.{ .if_type = .{
                        .pos = first_expr_token.start,
                        .type = t.getType(),
                    } }),
                };
            };
            if (!is_true) return .{ .statement_end = try vm.eat().evalBlock(after_rparen, .@"if") };
            return switch (try vm.evalBlock(after_rparen, .@"if")) {
                .complete => |end| .{ .statement_end = end },
                .break_parent => |block_break| return .{ .child_block_break = block_break },
                .continue_parent => @panic("todo"),
            };
        },
        .keyword_loop => {
            if (maybe_loop_ref.* != null) return vm.setError(.{ .static_error = .{
                .pos = first_token.start,
                .string = "cannot loop inside loop (end with break or continue at the same depth as the original loop)",
            } });
            maybe_loop_ref.* = first_token.end;
            return .{ .statement_end = first_token.end };
        },
        .keyword_break => {
            if (maybe_loop_ref.* == null) return .{ .direct_break_no_loop = first_token.end };
            maybe_loop_ref.* = null;
            return .{ .statement_end = first_token.end };
        },
        .keyword_continue => return .{ .@"continue" = first_token.start },
        .keyword_var => {
            const id_extent = blk: {
                const id_token = lex(vm.text, first_token.end);
                if (id_token.tag != .identifier) return vm.setError(.{ .unexpected_token = .{
                    .expected = "an identifier after 'var'",
                    .token = id_token,
                } });
                break :blk id_token.extent();
            };
            const after_equal = blk: {
                const token = lex(vm.text, id_extent.end);
                if (token.tag != .@"=") return vm.setError(.{ .unexpected_token = .{
                    .expected = "an '=' to initialize new var",
                    .token = token,
                } });
                break :blk token.end;
            };
            try vm.startSymbol(id_extent.start);
            const value_addr = vm.mem.top();
            const expr_first_token = lex(vm.text, after_equal);
            const after_expr = try vm.evalExpr(expr_first_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expresson to initialize new var",
                .token = expr_first_token,
            } });
            if (value_addr.eql(vm.mem.top())) return vm.setError(.{ .void_assignment = .{
                .id_extent = id_extent,
            } });
            try vm.endSymbol();
            return .{ .statement_end = after_expr };
        },
        .keyword_yield => {
            const expr_first_token = lex(vm.text, first_token.end);
            const expr_addr = vm.mem.top();
            const expr_end = try vm.evalExpr(expr_first_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expression after yield",
                .token = expr_first_token,
            } });
            if (expr_addr.eql(vm.mem.top())) return vm.setError(.{ .unexpected_type = .{
                .pos = expr_first_token.start,
                .expected = "an integer expression after yield",
                .actual = null,
            } });
            return .{ .yield = .{
                .block_resume = .{ .text_offset = expr_end, .loop_text_offset = maybe_loop_ref.* },
                .millis = switch (vm.pop(expr_addr)) {
                    .integer => |v| v,
                    else => |t| return vm.setError(.{ .unexpected_type = .{
                        .pos = expr_first_token.start,
                        .expected = "an integer expression after yield",
                        .actual = t.getType(),
                    } }),
                },
            } };
        },
        else => {},
    }

    const expr_addr = vm.mem.top();
    const expr_end = try vm.evalExpr(first_token) orelse return .{ .not_statement = first_token };
    const next_token = lex(vm.text, expr_end);
    if (next_token.tag != .@"=") {
        if (!vm.mem.top().eql(expr_addr)) {
            const expr_type, _ = vm.readValue(Type, expr_addr);
            return vm.setError(.{ .statement_result_ignored = .{
                .pos = first_token.start,
                .ignored_type = expr_type,
            } });
        }
        return .{ .statement_end = expr_end };
    }

    @panic("todo");
}

fn evalExpr(vm: *Vm, first_token: Token) error{Vm}!?usize {
    return vm.evalExprBinary(first_token, .comparison);
}
fn evalExprBinary(vm: *Vm, first_token: Token, maybe_priority: ?BinaryOpPriority) error{Vm}!?usize {
    const priority = maybe_priority orelse return vm.evalExprSingle(first_token);
    const first_expr_addr = vm.mem.top();
    var left_expr_pos = first_token.start;
    var after_expr = try vm.evalExprBinary(first_token, priority.next()) orelse return null;
    while (true) {
        const op_token = lex(vm.text, after_expr);
        const binary_op = BinaryOp.init(op_token.tag, priority) orelse return after_expr;
        const right_expr_addr = vm.mem.top();
        const right_token = lex(vm.text, op_token.end);
        after_expr = try vm.evalExprBinary(right_token, priority.next()) orelse return after_expr;
        try vm.executeBinaryOp(
            binary_op,
            left_expr_pos,
            first_expr_addr,
            right_token.start,
            right_expr_addr,
        );
        left_expr_pos = right_token.start;
    }
}
fn evalExprSingle(vm: *Vm, first_token: Token) error{Vm}!?usize {
    const expr_addr = vm.mem.top();
    var offset = try vm.evalPrimaryTypeExpr(first_token) orelse return null;
    while (true) {
        offset = try vm.evalExprSuffix(first_token, expr_addr, offset) orelse return offset;
    }
}
fn evalExprSuffix(
    vm: *Vm,
    expr_first_token: Token,
    expr_addr: Memory.Addr,
    suffix_start: usize,
) error{Vm}!?usize {
    const suffix_op_token = lex(vm.text, suffix_start);
    return switch (suffix_op_token.tag) {
        .l_bracket => {
            return vm.setError(.{ .not_implemented = "array index" });
        },
        .period => {
            const id_extent = blk: {
                const id_token = lex(vm.text, suffix_op_token.end);
                if (id_token.tag != .identifier) return vm.setError(.{ .unexpected_token = .{
                    .expected = "an identifier after '.'",
                    .token = id_token,
                } });
                break :blk id_token.extent();
            };
            if (expr_addr.eql(vm.mem.top())) return vm.setError(
                .{ .void_field = .{ .start = suffix_op_token.start } },
            );
            const expr_type_ptr, const value_addr = vm.readPointer(Type, expr_addr);
            return switch (expr_type_ptr.*) {
                .integer,
                .string_literal,
                // .c_string,
                .managed_string,
                .script_function,
                => vm.setError(.{ .no_field = .{
                    .start = suffix_op_token.start,
                    .field = id_extent,
                    .unexpected_type = expr_type_ptr.*,
                } }),
                .assembly => {
                    _, const end = vm.readValue(*const mono.Assembly, value_addr);
                    std.debug.assert(end.eql(vm.mem.top()));

                    // NOTE: we could short-circuit the grammar at this point
                    // and just try to lex as many DOT IDENTIFIERS as possible
                    // by creating a "ManagedId" which is the same code used to
                    // gather all the identifiers into one string later on.
                    // Maybe this would improve performance? I don't want to do
                    // this too early though because I want to ensure the grammar
                    // is correct.
                    // var namespace: ManagedId = .empty();
                    // var name: ManagedId = .empty();
                    // if (lexClass(vm.text, &namespace, &name, id_start)) |too_big_end| return vm.setError(.{
                    //     .id_too_big = .{ .start = id_start, .end = too_big_end },
                    // });

                    expr_type_ptr.* = .assembly_field;
                    // assembly already pushed
                    (try vm.push(usize)).* = id_extent.start;
                    return id_extent.end;
                },
                .assembly_field => {
                    _, const id_start_addr = vm.readValue(*const mono.Assembly, value_addr);
                    const id_start, const end = vm.readValue(usize, id_start_addr);
                    std.debug.assert(end.eql(vm.mem.top()));
                    std.debug.assert(lex(vm.text, id_start).tag == .identifier);
                    return id_extent.end;
                },
                .class => {
                    expr_type_ptr.* = .class_member;
                    // class already pushed
                    (try vm.push(usize)).* = id_extent.start;
                    return id_extent.end;
                },
                .class_member => {
                    return vm.setError(.{ .not_implemented = "class member" });
                },
                .object => vm.setError(.{ .not_implemented = "object fields" }),
            };
        },
        .l_paren => {
            if (expr_addr.eql(vm.mem.top())) return vm.setError(.{ .called_non_function = .{
                .start = expr_first_token.start,
                .unexpected_type = null,
            } });
            switch (vm.pop(expr_addr)) {
                .class_member => |member| {
                    const method_id_extent = blk: {
                        var it: DottedIterator = .init(vm.text, member.id_start);
                        var previous = it.id;
                        while (it.next(vm.text)) {
                            _ = &previous;
                            return vm.setError(.{ .not_implemented = "class member with multiple '.IDENTIFIER'" });
                        }
                        break :blk previous;
                    };
                    const method_id = try vm.managedId(method_id_extent);
                    const args_addr = vm.mem.top();
                    const args = try vm.evalFnCallArgsManaged(suffix_op_token.end);

                    // NOTE: we could push the args on the vm.mem stack, but, having a reasonable
                    //       max like 100 is probably fine right?
                    const max_arg_count = 100;
                    if (args.count > max_arg_count) return vm.setError(.{ .static_error = .{
                        .pos = suffix_op_token.start,
                        .string = "too many args for managed function (current max is 100)",
                    } });

                    const method = vm.mono_funcs.class_get_method_from_name(
                        member.class,
                        method_id.slice(),
                        args.count,
                    ) orelse return vm.setError(.{ .missing_method = .{
                        .class = member.class,
                        .id_extent = method_id_extent,
                        .arg_count = args.count,
                    } });
                    const method_sig = vm.mono_funcs.method_signature(method) orelse @panic(
                        "method has no signature?", // impossible right?
                    );
                    const return_type = vm.mono_funcs.signature_get_return_type(method_sig) orelse @panic(
                        "method has no return type?", // impossible right?
                    );

                    var managed_args_buf: [max_arg_count]*anyopaque = undefined;

                    var next_arg_addr = args_addr;
                    for (0..args.count) |arg_index| {
                        const arg_type, next_arg_addr = vm.readValue(Type, next_arg_addr);
                        const arg_value, next_arg_addr = vm.readAnyValue(arg_type, next_arg_addr);
                        managed_args_buf[arg_index] = blk: switch (arg_value) {
                            .string_literal => |extent| {
                                const slice = vm.text[extent.start + 1 .. extent.end - 1];
                                const str = vm.mono_funcs.string_new_len(
                                    vm.mono_funcs.domain_get().?,
                                    slice.ptr,
                                    std.math.cast(c_uint, slice.len) orelse return vm.setError(.{ .static_error = .{
                                        .pos = suffix_op_token.start,
                                        .string = "native string too long",
                                    } }),
                                ) orelse return vm.setError(.{ .static_error = .{
                                    .pos = suffix_op_token.start,
                                    .string = "native string to managed returned null",
                                } });
                                break :blk @ptrCast(@constCast(str));
                            },
                            .managed_string => |handle| {
                                const str = vm.mono_funcs.gchandle_get_target(handle);
                                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                                // const c_str = vm.mono_funcs.string_to_utf8(@ptrCast(@constCast(managed_args_buf[arg_index]))) orelse @panic("here");
                                // defer vm.mono_funcs.free(@ptrCast(@constCast(c_str)));
                                // std.debug.print("ManagedString value is '{s}'", .{std.mem.span(c_str)});
                                break :blk @constCast(str);
                            },
                            else => |a| {
                                std.log.info("TODO: implement converting '{t}' to managed arg", .{a});
                                return vm.setError(.{ .not_implemented = "call method with this kind of arg" });
                            },
                        };
                    }
                    std.debug.assert(next_arg_addr.eql(vm.mem.top()));

                    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                    // TODO: how do we know if we need an object
                    const object: ?*anyopaque = null;
                    // const params: ?**anyopaque = null;
                    var maybe_exception: ?*const mono.Object = null;

                    const maybe_result = vm.mono_funcs.runtime_invoke(
                        method,
                        object,
                        if (args.count == 0) null else @ptrCast(&managed_args_buf),
                        &maybe_exception,
                    );
                    vm.discardValues(args_addr);
                    _ = vm.mem.discardFrom(args_addr);

                    if (false) std.debug.print(
                        "Result=0x{x} Exception=0x{x}\n",
                        .{ @intFromPtr(maybe_result), @intFromPtr(maybe_exception) },
                    );
                    if (maybe_exception) |e| {
                        std.log.err("TODO: handle exception 0x{x}\n", .{@intFromPtr(e)});
                        return vm.setError(.{ .not_implemented = "handle exception" });
                    }
                    switch (vm.mono_funcs.type_get_type(return_type)) {
                        .void => if (maybe_result) |_| {
                            return vm.setError(.{ .not_implemented = "error message for calling managed function with void return type that returned something" });
                        },
                        .i4 => {
                            const result = maybe_result orelse return vm.setError(.{ .not_implemented = "error message for calling managed function with i4 return type that returned null" });
                            const unboxed: *align(1) i32 = @ptrCast(vm.mono_funcs.object_unbox(result));
                            std.log.info("Unboxed 32-bit return value {} (0x{0x})", .{unboxed.*});
                            (try vm.push(Type)).* = .integer;
                            (try vm.push(i64)).* = unboxed.*;
                        },
                        .string => {
                            const result = maybe_result orelse return vm.setError(.{ .not_implemented = "error message for calling managed function with string return type that returned null" });
                            // const c_string = vm.mono_funcs.string_to_utf8(result) orelse return vm.setError(.{
                            //     .static_error = .{
                            //         .pos = suffix_op_token.start,
                            //         .string = "managed string to native returned null",
                            //     },
                            // });
                            // errdefer vm.mono_funcs.free(@ptrCast(@constCast(c_string)));
                            // (try vm.push(Type)).* = .c_string;
                            // (try vm.push([*:0]const u8)).* = c_string;

                            // 0 means we don't require pinning
                            const handle = vm.mono_funcs.gchandle_new(result, 0);
                            errdefer vm.mono_funcs.gchandle_free(handle);
                            (try vm.push(Type)).* = .managed_string;
                            (try vm.push(mono.GcHandle)).* = handle;
                        },
                        else => |kind| {
                            std.debug.print("ReturnTypeKind={t}\n", .{kind});
                            return vm.setError(.{ .not_implemented = "managed return value of this type" });
                        },
                    }
                    return args.end;
                },
                .script_function => |param_start| {
                    const params = try vm.eat().evalParamDeclList(param_start);
                    const args_addr = vm.mem.top();
                    const after_args = try vm.evalFnCallArgs(.{ .script = params.count }, suffix_op_token.end);
                    var return_storage: ReturnStorage = .{};
                    _ = try vm.evalFunction(params.end, &return_storage, args_addr);
                    // TODO: in future we could allow the function to leave things on the stack
                    if (!args_addr.eql(vm.mem.top())) @panic("evalFunction left things on the stack");
                    if (return_storage.type) |return_type| {
                        _ = return_type;
                        // verify there is only one value on the stack
                        // var value_type, const value_addr = vm.
                        // @panic("todo");
                        return vm.setError(.{ .not_implemented = "function calls with return types" });
                    }
                    return after_args;
                },
                else => |value| return vm.setError(.{ .called_non_function = .{
                    .start = expr_first_token.start,
                    .unexpected_type = value.getType(),
                } }),
            }
        },
        else => null,
    };
}

fn pushValueFromAddr(vm: *Vm, src_type_addr: Memory.Addr) error{Vm}!void {
    const value_type, const value_addr = vm.readValue(Type, src_type_addr);
    switch (value_type) {
        .integer => {
            (try vm.push(Type)).* = .integer;
            const value_ptr = vm.mem.toPointer(i64, value_addr);
            (try vm.push(i64)).* = value_ptr.*;
        },
        .string_literal => {
            (try vm.push(Type)).* = .string_literal;
            const token_start_ptr = vm.mem.toPointer(usize, value_addr);
            (try vm.push(usize)).* = token_start_ptr.*;
        },
        // .c_string => {
        //     return vm.setError(.{ .not_implemented = "pushValueFromAddr c_string" });
        // },
        .managed_string => {
            return vm.setError(.{ .not_implemented = "pushValueFromAddr managed_string" });
        },
        .script_function => {
            (try vm.push(Type)).* = .script_function;
            (try vm.push(usize)).* = vm.mem.toPointer(usize, value_addr).*;
        },
        .assembly => {
            (try vm.push(Type)).* = .assembly;
            const assembly_ptr = vm.mem.toPointer(*const mono.Assembly, value_addr);
            (try vm.push(*const mono.Assembly)).* = assembly_ptr.*;
        },
        .assembly_field => {
            (try vm.push(Type)).* = .assembly_field;
            // const assembly_ptr, const some_addr = vm.readPointer(*const mono.Assembly, value_addr);
            // (try vm.push(*const mono.Assembly)).* = assembly_ptr.*;
            // _ = some_addr;
            return vm.setError(.{ .not_implemented = "pushValueFromAddr assembly_field" });
        },
        .class => {
            (try vm.push(Type)).* = .class;
            const class_ptr = vm.mem.toPointer(*const mono.Class, value_addr);
            (try vm.push(*const mono.Class)).* = class_ptr.*;
        },
        .class_member => {
            (try vm.push(Type)).* = .class_member;
            // const class_ptr = vm.mem.toPointer(*const mono.Class, value_addr);
            // (try vm.push(*const mono.Class)).* = class_ptr.*;
            return vm.setError(.{ .not_implemented = "pushValueFromAddr class_member" });
        },
        .object => {
            (try vm.push(Type)).* = .object;
            const object_ptr = vm.mem.toPointer(*const mono.Object, value_addr);
            (try vm.push(*const mono.Object)).* = object_ptr.*;
        },
    }
}

fn evalPrimaryTypeExpr(vm: *Vm, first_token: Token) error{Vm}!?usize {
    return switch (first_token.tag) {
        .identifier => {
            const string = vm.text[first_token.start..first_token.end];
            const entry = vm.lookup(string) orelse return vm.setError(
                .{ .undefined_identifier = first_token.extent() },
            );
            try vm.pushValueFromAddr(entry.type_addr);
            return first_token.end;
        },
        .string_literal => {
            (try vm.push(Type)).* = .string_literal;
            (try vm.push(usize)).* = first_token.start;
            return first_token.end;
        },
        .builtin => {
            const id = vm.text[first_token.start..first_token.end];
            const builtin = builtin_map.get(id) orelse return vm.setError(.{ .unknown_builtin = first_token });
            const next = try vm.eat().eatToken(first_token.end, .l_paren, "a '(' to start the builtin args");
            const args_addr = vm.mem.top();
            const args_end = try vm.evalFnCallArgs(.{ .builtin = builtin.params() }, next);
            try vm.evalBuiltin(first_token.extent(), builtin, args_addr);
            return args_end;
        },
        .l_paren => {
            const first_expr_token = lex(vm.text, first_token.end);
            const after_expr = try vm.evalExpr(first_expr_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expression after '('",
                .token = first_expr_token,
            } });
            const t = lex(vm.text, after_expr);
            if (t.tag != .r_paren) return vm.setError(.{ .unexpected_token = .{
                .expected = "a close paren ')' to end expression",
                .token = t,
            } });
            return t.end;
        },
        .number_literal => {
            const str = vm.text[first_token.start..first_token.end];
            const value = std.fmt.parseInt(i64, str, 10) catch |err| switch (err) {
                error.Overflow => return vm.setError(.{ .num_literal_overflow = first_token.extent() }),
                error.InvalidCharacter => return vm.setError(.{ .bad_num_literal = first_token.extent() }),
            };
            (try vm.push(Type)).* = .integer;
            (try vm.push(i64)).* = value;
            return first_token.end;
        },
        .keyword_new => {
            @panic("todo");
            // const id_extent = blk: {
            //     const token = lex(vm.text, first_token.end);
            //     if (token.tag != .identifier) return vm.setError(.{ .unexpected_token = .{
            //         .expected = "an identifier to follow 'new'",
            //         .token = token,
            //     } });
            //     break :blk token.extent();
            // };
            // const id_string = vm.text[id_extent.start..id_extent.end];
            // const symbol = vm.lookup(id_string) orelse return vm.setError(
            //     .{ .undefined_identifier = id_extent },
            // );
            // const symbol_type, const value_addr = vm.readValue(Type, symbol.value_addr);
            // if (symbol_type != .class) return vm.setError(.{ .new_non_class = .{
            //     .id_extent = id_extent,
            //     .actual_type = symbol_type,
            // } });
            // _ = value_addr;

            // const next = try vm.eat().eatToken(id_extent.end, .l_paren);
            // _ = next;
            // // const args_addr = vm.mem.top();
            // // const args_end = try vm.evalFnCallArgs(builtin.paramCount(), .{ .builtin = builtin.params() }, next);
            // return vm.setError(.{ .not_implemented = "new expression" });
        },
        else => null,
    };
}

fn evalFnCallArgsManaged(vm: *Vm, start: usize) error{Vm}!struct {
    count: u16,
    end: usize,
} {
    var arg_index: u16 = 0;
    var text_offset = start;
    while (true) {
        const first_token = lex(vm.text, text_offset);
        if (first_token.tag == .r_paren) return .{
            .count = arg_index,
            .end = first_token.end,
        };
        const arg_addr = vm.mem.top();
        text_offset = try vm.evalExpr(first_token) orelse return vm.setError(.{ .unexpected_token = .{
            .expected = "an expression",
            .token = first_token,
        } });
        if (arg_addr.eql(vm.mem.top())) return vm.setError(.{ .void_argument = .{
            .arg_index = arg_index,
            .first_arg_token = first_token,
        } });

        {
            // should we perform any checks
            const arg_type = vm.mem.toPointer(Type, arg_addr).*;
            if (!arg_type.canMarshal()) return vm.setError(.{ .cant_marshal = .{
                .pos = first_token.start,
                .type = arg_type,
            } });
        }

        arg_index += 1;

        const second_token = lex(vm.text, text_offset);
        text_offset = second_token.end;
        switch (second_token.tag) {
            .r_paren => return .{ .count = arg_index, .end = second_token.end },
            .comma => {},
            else => return vm.setError(.{ .unexpected_token = .{
                .expected = "a ',' or close paren ')'",
                .token = second_token,
            } }),
        }
    }
}

const Params = union(enum) {
    builtin: ?[]const BuiltinParamType,
    script: u16,
    pub fn count(params: Params) ?u16 {
        return switch (params) {
            .builtin => |maybe_types| @intCast((maybe_types orelse return null).len),
            .script => |c| c,
        };
    }
    pub fn indexInRange(params: Params, index: u16) bool {
        return switch (params) {
            .builtin => |maybe_types| index < (maybe_types orelse return true).len,
            .script => |c| index < c,
        };
    }
    pub fn expectedType(params: Params, arg_index: u16) ?Type {
        return switch (params) {
            .builtin => |maybe_param_types| {
                const param_types = maybe_param_types orelse return null;
                return if (arg_index < param_types.len) switch (param_types[arg_index]) {
                    .anything => null,
                    .concrete => |t| t,
                } else null;
            },
            .script => null,
        };
    }
};

fn evalFnCallArgs(vm: *Vm, params: Params, start: usize) error{Vm}!usize {
    var arg_index: u16 = 0;
    var text_offset = start;
    while (true) {
        const first_token = lex(vm.text, text_offset);
        if (first_token.tag == .r_paren) {
            text_offset = first_token.end;
            break;
        }
        if (params.indexInRange(arg_index)) {
            const arg_addr = vm.mem.top();
            text_offset = try vm.evalExpr(first_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } });
            if (arg_addr.eql(vm.mem.top())) return vm.setError(.{ .void_argument = .{
                .arg_index = arg_index,
                .first_arg_token = first_token,
            } });
            const arg_type = vm.mem.toPointer(Type, arg_addr).*;
            if (params.expectedType(arg_index)) |t| if (t != arg_type) return vm.setError(.{ .arg_type = .{
                .arg_pos = first_token.start,
                .arg_index = arg_index,
                .expected = t,
                .actual = arg_type,
            } });
        } else {
            text_offset = try vm.eat().evalExpr(first_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } });
        }

        if (arg_index == std.math.maxInt(u16)) return vm.setError(.{ .arg_count = .{
            .start = start,
            .expected = params.count() orelse std.math.maxInt(u16),
            .actual = @as(u17, std.math.maxInt(u16)) + 1,
        } });
        arg_index += 1;

        {
            const token = lex(vm.text, text_offset);
            text_offset = token.end;
            switch (token.tag) {
                .r_paren => break,
                .comma => {},
                else => return vm.setError(.{ .unexpected_token = .{
                    .expected = "a ',' or close paren ')'",
                    .token = token,
                } }),
            }
        }
    }
    if (params.count()) |expected_count| if (arg_index != expected_count) return vm.setError(.{
        .arg_count = .{
            .start = start,
            .expected = expected_count,
            .actual = arg_index,
        },
    });
    return text_offset;
}

fn evalBuiltin(
    vm: *Vm,
    builtin_extent: Extent,
    builtin: Builtin,
    args_addr: Memory.Addr,
) error{Vm}!void {
    switch (builtin) {
        .@"@Nothing" => {},
        .@"@Exit" => {
            vm.error_result = .exit;
            return error.Vm;
        },
        .@"@Log" => {
            var buffer: [1000]u8 = undefined;
            var stderr = std.fs.File.stderr().writer(&buffer);
            vm.log(&stderr.interface, args_addr) catch |err| switch (err) {
                error.WriteFailed => return vm.setError(.{ .log_error = .{
                    .pos = builtin_extent.start,
                    .err = stderr.err orelse error.Unexpected,
                } }),
            };
            vm.discardValues(args_addr);
            _ = vm.mem.discardFrom(args_addr);
        },
        .@"@LogAssemblies" => {
            var context: LogAssemblies = .{ .vm = vm, .index = 0 };
            std.log.info("mono_assembly_foreach:", .{});
            vm.mono_funcs.assembly_foreach(&logAssemblies, &context);
            std.log.info("mono_assembly_foreach done", .{});
        },
        .@"@Assembly" => {
            const extent = switch (vm.pop(args_addr)) {
                .string_literal => |e| e,
                else => unreachable,
            };
            var context: FindAssembly = .{
                .vm = vm,
                .index = 0,
                .needle = vm.text[extent.start + 1 .. extent.end - 1],
                .match = null,
            };
            vm.mono_funcs.assembly_foreach(&findAssembly, &context);
            const match = context.match orelse return vm.setError(
                .{ .assembly_not_found = extent },
            );
            (try vm.push(Type)).* = .assembly;
            (try vm.push(*const mono.Assembly)).* = match;
        },
        .@"@Class" => {
            const field = switch (vm.pop(args_addr)) {
                .assembly_field => |f| f,
                else => unreachable,
            };
            var namespace: ManagedId = .empty();
            var name: ManagedId = .empty();
            if (lexClass(vm.text, &namespace, &name, field.id_start)) |too_big_end| return vm.setError(.{
                .id_too_big = .{ .start = field.id_start, .end = too_big_end },
            });
            const image = vm.mono_funcs.assembly_get_image(field.assembly) orelse @panic(
                "mono_assembly_get_image returned null",
            );
            const class = vm.mono_funcs.class_from_name(
                image,
                namespace.slice(),
                name.slice(),
            ) orelse return vm.setError(.{ .missing_class = .{
                .assembly = field.assembly,
                .id_start = field.id_start,
            } });
            (try vm.push(Type)).* = .class;
            (try vm.push(*const mono.Class)).* = class;
        },
        .@"@Discard" => {
            var value = vm.pop(args_addr);
            value.discard(vm.mono_funcs);
        },
        // .@"@ScheduleMs" => {
        //     if (args_addr.eql(vm.mem.top())) return vm.setError(.{ .static_error = .{
        //         .pos = builtin_extent.start,
        //         .string = "@ScheduleMs requires at least 2 args (millisecond count and function id) but got 0",
        //     } });
        //     const ms_count: i64, const callable_addr = blk: {
        //         const v, const next_arg_addr = vm.read(args_addr);
        //         break :blk switch (v) {
        //             .integer => |v_int| .{ v_int, next_arg_addr },
        //             else => |t| return vm.setError(.{ .arg_type_call_pos = .{
        //                 .call_pos = builtin_extent.start,
        //                 .arg_index = 0,
        //                 .expected = .integer,
        //                 .actual = t.getType(),
        //             } }),
        //         };
        //     };
        //     if (callable_addr.eql(vm.mem.top())) return vm.setError(.{ .static_error = .{
        //         .pos = builtin_extent.start,
        //         .string = "@ScheduleMs requires at least 2 args (millisecond count and function id) but got 1",
        //     } });
        //     const Callable = union(enum) {
        //         script_function: usize,
        //     };
        //     const callable: Callable, const callable_args_addr = blk: {
        //         const v: Value, const callable_args_addr = vm.read(args_addr);
        //         break :blk switch (v) {
        //             .script_function => |pos| break :blk .{ .{ .script_function = pos }, callable_args_addr },
        //             else => |t| return vm.setError(.{ .arg_type_expected = .{
        //                 .call_pos = builtin_extent.start,
        //                 .arg_index = 0,
        //                 .expected = "a callable object",
        //                 .actual = t.getType(),
        //             } }),
        //         };
        //     };
        //     _ = ms_count;
        //     _ = callable;
        //     _ = callable_args_addr;
        //     return vm.setError(.{ .not_implemented = "@ScheduleMs" });
        // },
        .@"@ScheduleTests" => {
            vm.tests_scheduled = true;
        },
    }
}

fn log(vm: *Vm, writer: *std.Io.Writer, args_addr: Memory.Addr) error{WriteFailed}!void {
    try writer.writeAll("@Log: ");
    // {
    //     var time: win32.SYSTEMTIME = undefined;
    //     win32.GetSystemTime(&time);
    //     writer.print(
    //         "mod: {:0>2}:{:0>2}:{:0>2}.{:0>3}|{}|" ++ level_txt ++ scope_suffix ++ "|",
    //         .{ time.wHour, time.wMinute, time.wSecond, time.wMilliseconds, win32.GetCurrentThreadId() },
    //     ) catch |err| std.debug.panic("print log prefix failed with {s}", .{@errorName(err)});
    // }

    {
        var next_addr = args_addr;
        while (!next_addr.eql(vm.mem.top())) {
            const value_type, next_addr = vm.readValue(Type, next_addr);
            std.debug.assert(!next_addr.eql(vm.mem.top()));
            const value, next_addr = vm.readAnyValue(value_type, next_addr);
            switch (value) {
                .integer => |i| try writer.print("{d}", .{i}),
                .string_literal => |e| try writer.print("{s}", .{vm.text[e.start + 1 .. e.end - 1]}),
                .managed_string => {
                    @panic("todo");
                },
                .script_function => |start| try writer.print("<script function:{}>", .{start}),
                .assembly => try writer.print("<assembly>", .{}),
                .assembly_field => try writer.print("<assembly-field>", .{}),
                .class => try writer.print("<class>", .{}),
                .class_member => try writer.print("<class-member", .{}),
            }
        }
    }
    try writer.writeAll("\n");
    try writer.flush();
}

const DottedIterator = struct {
    id: Extent,
    pub fn init(text: []const u8, start: usize) DottedIterator {
        const token = lex(text, start);
        std.debug.assert(token.tag == .identifier);
        return .{ .id = token.extent() };
    }
    pub fn next(it: *DottedIterator, text: []const u8) bool {
        const period_token = lex(text, it.id.end);
        if (period_token.tag != .period) return false;
        const id_token = lex(text, period_token.end);
        if (id_token.tag != .identifier) return false;
        it.id = id_token.extent();
        return true;
    }
};

// returns null on success, otherwise, the end of the last identifier where it got too big
fn lexClass(text: []const u8, namespace: *ManagedId, name: *ManagedId, start: usize) ?usize {
    var it: DottedIterator = .init(text, start);
    var previous = it.id;
    while (it.next(text)) {
        if (namespace.len > 0) namespace.append(".") catch return previous.end;
        namespace.append(text[previous.start..previous.end]) catch return previous.end;
        previous = it.id;
    }
    name.append(text[previous.start..previous.end]) catch return previous.end;
    return null;
}

const SymbolEntry = struct {
    id_extent: Extent,
    type_addr: Memory.Addr,
};
fn lookup(vm: *Vm, needle: []const u8) ?SymbolEntry {
    // if (builtin_symbols.get(symbol)) |value| return value;
    var id_addr = switch (vm.symbol_state) {
        .none => return null,
        .evaluating => |*symbol_addrs| symbol_addrs.maybe_previous_newest orelse return null,
        .stable => |*symbol_addrs| symbol_addrs.newest,
    };
    while (true) {
        const id_start, const after_id_addr = vm.readValue(usize, id_addr);
        const id = lex(vm.text, id_start);
        std.debug.assert(id.tag == .identifier);
        var previous_id_addr: Memory.Addr = undefined;
        var type_addr: Memory.Addr = undefined;
        if (id_addr.eql(.zero)) {
            type_addr = after_id_addr;
        } else {
            previous_id_addr, type_addr = vm.readValue(Memory.Addr, after_id_addr);
        }
        if (std.mem.eql(u8, needle, vm.text[id.start..id.end])) return .{
            .id_extent = id.extent(),
            .type_addr = type_addr,
        };
        if (id_addr.eql(.zero)) break;
        id_addr = previous_id_addr;
    }
    return null;
}

fn push(vm: *Vm, comptime T: type) error{Vm}!*T {
    return vm.mem.push(T) catch return vm.setError(.oom);
}

fn readAnyValue(vm: *Vm, value_type: Type, addr: Memory.Addr) struct { Value, Memory.Addr } {
    switch (value_type) {
        .integer => {
            const value, const end = vm.readValue(i64, addr);
            return .{ .{ .integer = value }, end };
        },
        .string_literal => {
            const start, const end = vm.readValue(usize, addr);
            std.debug.assert(vm.text[start] == '"');
            const token = lex(vm.text, start);
            std.debug.assert(token.start == start);
            std.debug.assert(token.tag == .string_literal);
            std.debug.assert(vm.text[token.end - 1] == '"');
            return .{ .{ .string_literal = token.extent() }, end };
        },
        // .c_string => {
        //     const ptr, const end = vm.readValue([*:0]const u8, addr);
        //     return .{ .{ .c_string = ptr }, end };
        // },
        .managed_string => {
            const handle, const end = vm.readValue(mono.GcHandle, addr);
            return .{ .{ .managed_string = handle }, end };
        },
        .script_function => {
            const param_start, const end = vm.readValue(usize, addr);
            return .{ .{ .script_function = param_start }, end };
        },
        .assembly => {
            const assembly, const end = vm.readValue(*const mono.Assembly, addr);
            return .{ .{ .assembly = assembly }, end };
        },
        .assembly_field => {
            const assembly, const id_start_addr = vm.readValue(*const mono.Assembly, addr);
            const id_start, const end = vm.readValue(usize, id_start_addr);
            return .{ .{ .assembly_field = .{
                .assembly = assembly,
                .id_start = id_start,
            } }, end };
        },
        .class => {
            const class, const end = vm.readValue(*const mono.Class, addr);
            return .{ .{ .class = class }, end };
        },
        .class_member => {
            const class, const id_start_addr = vm.readValue(*const mono.Class, addr);
            const id_start, const end = vm.readValue(usize, id_start_addr);
            return .{ .{ .class_member = .{
                .class = class,
                .id_start = id_start,
            } }, end };
        },
        .object => @panic("implement readValue2 for object"),
    }
}

fn read(vm: *Vm, addr: Memory.Addr) struct { Value, Memory.Addr } {
    const value_type, const value_addr = vm.readValue(Type, addr);
    return vm.readAnyValue(value_type, value_addr);
}
fn pop(vm: *Vm, addr: Memory.Addr) Value {
    const value_type, const value_addr = vm.readValue(Type, addr);
    const value, const end = vm.readAnyValue(value_type, value_addr);
    std.debug.assert(end.eql(vm.mem.top()));
    // TODO: add check that scans to see if anyone is pointing to discarded memory?
    _ = vm.mem.discardFrom(addr);
    return value;
}
fn readPointer(vm: *Vm, comptime T: type, addr: Memory.Addr) struct { *T, Memory.Addr } {
    return .{ vm.mem.toPointer(T, addr), vm.mem.after(T, addr) };
}
fn readValue(vm: *Vm, comptime T: type, addr: Memory.Addr) struct { T, Memory.Addr } {
    return .{ vm.mem.toPointer(T, addr).*, vm.mem.after(T, addr) };
}

const Value = union(enum) {
    integer: i64,
    string_literal: Extent,
    // c_string: [*:0]const u8,
    managed_string: mono.GcHandle,
    script_function: usize,
    assembly: *const mono.Assembly,
    assembly_field: struct {
        assembly: *const mono.Assembly,
        id_start: usize,
    },
    class: *const mono.Class,
    class_member: struct {
        class: *const mono.Class,
        id_start: usize,
    },
    pub fn discard(value: *Value, mono_funcs: *const mono.Funcs) void {
        switch (value.*) {
            .integer => {},
            .string_literal => {},
            // .c_string => |ptr| mono_funcs.free(@ptrCast(@constCast(ptr))),
            .managed_string => |handle| mono_funcs.gchandle_free(handle),
            .script_function => {},
            .assembly => {},
            .assembly_field => {},
            .class => {},
            .class_member => {},
        }
        value.* = undefined;
    }
    pub fn getType(value: *const Value) Type {
        return switch (value.*) {
            .integer => .integer,
            .string_literal => .string_literal,
            // .c_string => .c_string,
            .managed_string => .managed_string,
            .script_function => .script_function,
            .assembly => .assembly,
            .assembly_field => .assembly_field,
            .class => .class,
            .class_member => .class_member,
        };
    }
};

fn managedId(vm: *Vm, extent: Extent) error{Vm}!ManagedId {
    const len = extent.end - extent.start;
    if (len > ManagedId.max) return vm.setError(.{ .id_too_big = extent });
    var result: ManagedId = .{ .buf = undefined, .len = @intCast(len) };
    @memcpy(result.buf[0..len], vm.text[extent.start..extent.end]);
    result.buf[len] = 0;
    return result;
}

fn eat(vm: *Vm) VmEat {
    return .{ .text = vm.text, .error_result_ref = &vm.error_result };
}
const VmEat = struct {
    text: []const u8,
    error_result_ref: *ErrorResult,

    fn setError(vm: VmEat, e: Error) error{Vm} {
        vm.error_result_ref.* = .{ .err = e };
        return error.Vm;
    }

    fn eatToken(vm: VmEat, start: usize, expected_tag: Token.Tag, expected: [:0]const u8) error{Vm}!usize {
        const t = lex(vm.text, start);
        if (t.tag != expected_tag) return vm.setError(.{
            .unexpected_token = .{ .expected = expected, .token = t },
        });
        return t.end;
    }

    pub fn evalBlock(vm: VmEat, start: usize, comptime kind: enum { function, @"if" }) error{Vm}!usize {
        const body_start = blk: {
            const token = lex(vm.text, start);
            if (token.tag != .l_brace) return vm.setError(.{ .unexpected_token = .{
                .expected = "an open brace '{' to start " ++ switch (kind) {
                    .function => "function body",
                    .@"if" => "if block",
                },
                .token = token,
            } });
            break :blk token.end;
        };

        var offset: usize = body_start;
        while (true) {
            const after_statement = switch (try vm.evalStatement(offset)) {
                .not_statement => |token| {
                    if (token.tag == .r_brace) return token.end;
                    return vm.setError(.{ .unexpected_token = .{
                        .expected = "a statement",
                        .token = token,
                    } });
                },
                .statement_end => |end| end,
                .loop_escape => |end| end,
            };
            std.debug.assert(after_statement > offset);
            offset = after_statement;
        }
    }

    pub fn remainingBlock(vm: VmEat, start: usize) error{Vm}!usize {
        var offset = start;
        while (true) {
            const new_offset = blk: switch (try vm.evalStatement(offset)) {
                .not_statement => |token| {
                    if (token.tag == .r_brace) return token.end;
                    return vm.setError(.{ .unexpected_token = .{
                        .expected = "a statement",
                        .token = token,
                    } });
                },
                .statement_end => |end| {
                    std.debug.assert(end > offset);
                    break :blk end;
                },
                .loop_escape => |end| {
                    std.debug.assert(end > offset);
                    break :blk end;
                },
            };
            std.debug.assert(new_offset != offset);
            offset = new_offset;
        }
    }

    fn evalStatement(vm: VmEat, start: usize) error{Vm}!union(enum) {
        not_statement: Token,
        statement_end: usize,
        loop_escape: usize,
    } {
        const first_token = lex(vm.text, start);
        switch (first_token.tag) {
            .identifier => {
                const second_token = lex(vm.text, first_token.end);
                if (second_token.tag == .@"=") {
                    const expr_first_token = lex(vm.text, second_token.end);
                    const after_expr = try vm.evalExpr(expr_first_token) orelse return vm.setError(.{ .unexpected_token = .{
                        .expected = "an expresson",
                        .token = expr_first_token,
                    } });
                    return .{ .statement_end = after_expr };
                }
            },
            .keyword_fn => @panic("todo"),
            .keyword_if => {
                const after_lparen = try vm.eatToken(
                    first_token.end,
                    .l_paren,
                    "a '(' to start the if conditional",
                );
                const first_expr_token = lex(vm.text, after_lparen);
                const after_expr = try vm.evalExpr(first_expr_token) orelse return vm.setError(.{ .unexpected_token = .{
                    .expected = "an expression inside the if conditional",
                    .token = first_expr_token,
                } });
                const after_rparen = try vm.eatToken(
                    after_expr,
                    .r_paren,
                    "a ')' to finish the if conditional",
                );
                return .{ .statement_end = try vm.evalBlock(after_rparen, .@"if") };
            },
            .keyword_loop => return .{ .statement_end = first_token.end },
            .keyword_break,
            .keyword_continue,
            => return .{ .loop_escape = first_token.end },
            .keyword_yield => {
                const expr_first_token = lex(vm.text, first_token.end);
                const expr_end = try vm.evalExpr(expr_first_token) orelse return vm.setError(.{ .unexpected_token = .{
                    .expected = "an expression after yield",
                    .token = expr_first_token,
                } });
                return .{ .statement_end = expr_end };
            },
            else => {},
        }

        const expr_end = try vm.evalExpr(first_token) orelse return .{ .not_statement = first_token };
        const next_token = lex(vm.text, expr_end);
        if (next_token.tag != .@"=") return .{ .statement_end = expr_end };

        @panic("todo");
    }

    fn evalExpr(vm: VmEat, first_token: Token) error{Vm}!?usize {
        return vm.evalExprBinary(first_token, .comparison);
    }

    fn evalExprBinary(vm: VmEat, first_token: Token, maybe_priority: ?BinaryOpPriority) error{Vm}!?usize {
        const priority = maybe_priority orelse return vm.evalExprSingle(first_token);
        var left_expr_pos = first_token.start;
        var after_expr = try vm.evalExprBinary(first_token, priority.next()) orelse return null;
        while (true) {
            const op_token = lex(vm.text, after_expr);
            _ = BinaryOp.init(op_token.tag, priority) orelse return after_expr;
            const right_token = lex(vm.text, op_token.end);
            after_expr = try vm.evalExprBinary(right_token, priority.next()) orelse return after_expr;
            left_expr_pos = right_token.start;
        }
    }

    fn evalExprSingle(vm: VmEat, first_token: Token) error{Vm}!?usize {
        var offset = try vm.evalPrimaryTypeExpr(first_token) orelse return null;
        while (true) {
            offset = try vm.evalExprSuffix(offset) orelse return offset;
        }
    }

    fn evalExprSuffix(vm: VmEat, suffix_start: usize) error{Vm}!?usize {
        const suffix_op_token = lex(vm.text, suffix_start);
        return switch (suffix_op_token.tag) {
            .l_bracket => {
                return vm.setError(.{ .not_implemented = "array index" });
            },
            .period => {
                const id_token = lex(vm.text, suffix_op_token.end);
                if (id_token.tag != .identifier) return vm.setError(.{ .unexpected_token = .{
                    .expected = "an identifier after '.'",
                    .token = id_token,
                } });
                return id_token.end;
            },
            .l_paren => return try vm.evalFnCallArgs(suffix_op_token.end),
            else => null,
        };
    }

    fn evalPrimaryTypeExpr(vm: VmEat, first_token: Token) error{Vm}!?usize {
        return switch (first_token.tag) {
            .identifier,
            .string_literal,
            .number_literal,
            => return first_token.end,
            .builtin => {
                const after_l_paren = try vm.eatToken(first_token.end, .l_paren, "a '(' to start the if conditional");
                return try vm.evalFnCallArgs(after_l_paren);
            },
            .keyword_new => {
                @panic("todo");
                // const after_id = try vm.eatToken(first_token.end, .identifier);
                // const after_l_paren = try vm.eatToken(after_id, .l_paren);
                // return try vm.evalFnCallArgs(after_l_paren);
            },
            else => null,
        };
    }
    fn evalFnCallArgs(vm: VmEat, start: usize) error{Vm}!usize {
        var offset = start;
        while (true) {
            const first_token = lex(vm.text, offset);
            if (first_token.tag == .r_paren) {
                offset = first_token.end;
                break;
            }
            offset = try vm.evalExpr(first_token) orelse return vm.setError(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } });
            {
                const token = lex(vm.text, offset);
                offset = token.end;
                switch (token.tag) {
                    .r_paren => break,
                    .comma => {},
                    else => return vm.setError(.{ .unexpected_token = .{
                        .expected = "a ',' or close paren ')'",
                        .token = token,
                    } }),
                }
            }
        }
        return offset;
    }
    fn evalParamDeclList(vm: VmEat, start: usize) error{Vm}!struct {
        count: u16,
        end: usize,
    } {
        var param_count: u16 = 0;
        var offset = start;
        while (true) {
            const first_token = lex(vm.text, offset);
            offset = first_token.end;
            switch (first_token.tag) {
                .r_paren => return .{ .count = param_count, .end = first_token.end },
                .identifier => {},
                else => return vm.setError(.{ .unexpected_token = .{
                    .expected = "an identifier or close paren ')'",
                    .token = first_token,
                } }),
            }
            if (param_count == std.math.maxInt(u16)) return vm.setError(.{ .not_implemented = "more than 65535 args" });
            param_count += 1;
            const second_token = lex(vm.text, offset);
            offset = second_token.end;
            switch (second_token.tag) {
                .r_paren => return .{ .count = param_count, .end = second_token.end },
                .comma => {},
                else => return vm.setError(.{ .unexpected_token = .{
                    .expected = "an comma ',' or close paren ')'",
                    .token = first_token,
                } }),
            }
        }
    }
};

fn executeBinaryOp(
    vm: *Vm,
    op: BinaryOp,
    left_text_pos: usize,
    left_addr: Memory.Addr,
    right_text_pos: usize,
    right_addr: Memory.Addr,
) error{Vm}!void {
    if (left_addr.eql(right_addr)) return vm.setError(.{ .binary_operand_nothing = .{
        .pos = left_text_pos,
        .op = op,
    } });
    if (right_addr.eql(vm.mem.top())) return vm.setError(.{ .binary_operand_nothing = .{
        .pos = right_text_pos,
        .op = op,
    } });
    const right_value = vm.pop(right_addr);
    const right_i64 = switch (right_value) {
        .integer => |i| i,
        else => |t| return vm.setError(.{ .binary_operand_type = .{
            .pos = right_text_pos,
            .op = op,
            .expects = "integers",
            .actual = t.getType(),
        } }),
    };
    const left_value = vm.pop(left_addr);
    const left_i64 = switch (left_value) {
        .integer => |i| i,
        else => |t| return vm.setError(.{ .binary_operand_type = .{
            .pos = left_text_pos,
            .op = op,
            .expects = "integers",
            .actual = t.getType(),
        } }),
    };
    const value: i64, const overflow: u1 = blk: switch (op) {
        .@"+" => @addWithOverflow(left_i64, right_i64),
        .@"/" => {
            if (right_i64 == 0) return vm.setError(.{
                .divide_by_0 = .{ .pos = right_text_pos },
            });
            break :blk .{ @divTrunc(left_i64, right_i64), 0 };
        },
        .@"==" => .{ if (left_i64 == right_i64) 1 else 0, 0 },
        .@"!=" => .{ if (left_i64 != right_i64) 1 else 0, 0 },
        .@"<" => .{ if (left_i64 < right_i64) 1 else 0, 0 },
        .@"<=" => .{ if (left_i64 <= right_i64) 1 else 0, 0 },
        .@">" => .{ if (left_i64 > right_i64) 1 else 0, 0 },
        .@">=" => .{ if (left_i64 >= right_i64) 1 else 0, 0 },
    };
    if (overflow == 1) return vm.setError(.{ .overflow_i64 = .{
        .pos = right_text_pos,
        .op = op,
        .left_i64 = left_i64,
        .right_i64 = right_i64,
    } });
    (try vm.push(Type)).* = .integer;
    (try vm.push(i64)).* = value;
}

const FindAssembly = struct {
    vm: *Vm,
    index: usize,
    needle: []const u8,
    match: ?*const mono.Assembly,
};
fn findAssembly(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *const mono.Assembly = @ptrCast(assembly_opaque);
    const ctx: *FindAssembly = @ptrCast(@alignCast(user_data));
    defer ctx.index += 1;
    const name = ctx.vm.mono_funcs.assembly_get_name(assembly) orelse {
        std.log.err("  assembly[{}] get name failed", .{ctx.index});
        return;
    };
    const str = ctx.vm.mono_funcs.assembly_name_get_name(name) orelse {
        std.log.err(
            "  assembly[{}] mono_assembly_name_get_name failed (assembly_ptr=0x{x}, name_ptr=0x{x})",
            .{ ctx.index, @intFromPtr(assembly), @intFromPtr(name) },
        );
        return;
    };
    const slice = std.mem.span(str);
    if (std.mem.eql(u8, slice, ctx.needle)) {
        ctx.match = assembly;
    }
    // std.log.info("  assembly[{}] name='{s}'", .{ ctx.index, std.mem.span(str) });
}

const LogAssemblies = struct {
    vm: *Vm,
    index: usize,
};
fn logAssemblies(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *const mono.Assembly = @ptrCast(assembly_opaque);
    const ctx: *LogAssemblies = @ptrCast(@alignCast(user_data));
    defer ctx.index += 1;
    const name = ctx.vm.mono_funcs.assembly_get_name(assembly) orelse {
        std.log.err("  assembly[{}] get name failed", .{ctx.index});
        return;
    };
    const str = ctx.vm.mono_funcs.assembly_name_get_name(name) orelse {
        std.log.err(
            "  assembly[{}] mono_assembly_name_get_name failed (assembly_ptr=0x{x}, name_ptr=0x{x})",
            .{ ctx.index, @intFromPtr(assembly), @intFromPtr(name) },
        );
        return;
    };
    std.log.info("  assembly[{}] name='{s}'", .{ ctx.index, std.mem.span(str) });
}

const BuiltinParamType = union(enum) {
    anything,
    concrete: Type,
};

const Builtin = enum {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // temporary builtin, remove this later
    @"@Nothing",
    @"@Exit",
    @"@Log",
    @"@LogAssemblies",
    @"@Assembly",
    @"@Class",
    @"@Discard",
    // @"@ScheduleMs",
    @"@ScheduleTests",
    pub fn params(builtin: Builtin) ?[]const BuiltinParamType {
        return switch (builtin) {
            .@"@Nothing" => &.{},
            .@"@Exit" => &.{},
            .@"@Log" => null,
            .@"@LogAssemblies" => &.{},
            .@"@Assembly" => &.{.{ .concrete = .string_literal }},
            .@"@Class" => &.{.{ .concrete = .assembly_field }},
            .@"@Discard" => &.{.anything},
            // .@"@ScheduleMs" => null,
            .@"@ScheduleTests" => &.{},
        };
    }
};
pub const builtin_map = std.StaticStringMap(Builtin).initComptime(.{
    .{ "@Nothing", .@"@Nothing" },
    .{ "@Exit", .@"@Exit" },
    .{ "@Log", .@"@Log" },
    .{ "@LogAssemblies", .@"@LogAssemblies" },
    .{ "@Assembly", .@"@Assembly" },
    .{ "@Class", .@"@Class" },
    .{ "@Discard", .@"@Discard" },
    // .{ "@ScheduleMs", .@"@ScheduleMs" },
    .{ "@ScheduleTests", .@"@ScheduleTests" },
});

const BinaryOpPriority = enum {
    comparison,
    math,
    pub fn next(priority: BinaryOpPriority) ?BinaryOpPriority {
        return switch (priority) {
            .comparison => .math,
            .math => null,
        };
    }
};
const BinaryOp = enum {
    // math
    @"+",
    @"/",
    // comparison
    @"==",
    @"!=",
    @"<",
    @"<=",
    @">",
    @">=",
    pub fn init(tag: Token.Tag, priority: BinaryOpPriority) ?BinaryOp {
        return switch (tag) {
            .invalid,
            .identifier,
            .string_literal,
            .eof,
            .builtin,
            .@"!",
            // TODO: maybe this should be allowed syntactically but then be a semantic error?
            .@"=",
            .l_paren,
            .r_paren,
            .l_brace,
            .r_brace,
            .l_bracket,
            .r_bracket,
            .period,
            .comma,
            .number_literal,
            .keyword_break,
            .keyword_continue,
            .keyword_fn,
            .keyword_if,
            .keyword_new,
            .keyword_var,
            .keyword_loop,
            .keyword_yield,
            => null,
            .plus => if (priority == .math) .@"+" else null,
            .slash => if (priority == .math) .@"/" else null,
            .@"==" => if (priority == .comparison) .@"==" else null,
            .@"!=" => if (priority == .comparison) .@"!=" else null,
            .@"<" => if (priority == .comparison) .@"<" else null,
            .@"<=" => if (priority == .comparison) .@"<=" else null,
            .@">" => if (priority == .comparison) .@">" else null,
            .@">=" => if (priority == .comparison) .@">=" else null,
        };
    }
};

const Token = struct {
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

    // pub fn isVoid(t: Token, text: []const u8) bool {
    //     return switch (t.tag) {
    //         .identifier => std.mem.eql(u8, text[t.start..t.end], "void"),
    //         else => false,
    //     };
    // }

    pub const Tag = enum {
        invalid,
        // invalid_periodasterisks,
        identifier,
        string_literal,
        // multiline_string_literal_line,
        // char_literal,
        eof,
        builtin,
        @"!",
        // pipe,
        // pipe_pipe,
        // pipe_equal,
        @"=",
        @"==",
        @"!=",
        l_paren,
        r_paren,
        // semicolon,
        // percent,
        // percent_equal,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        period,
        // period_asterisk,
        // ellipsis2,
        // ellipsis3,
        // caret,
        // caret_equal,
        plus,
        // plus_plus,
        // plus_equal,
        // plus_percent,
        // plus_percent_equal,
        // plus_pipe,
        // plus_pipe_equal,
        // minus,
        // minus_equal,
        // minus_percent,
        // minus_percent_equal,
        // minus_pipe,
        // minus_pipe_equal,
        // asterisk,
        // asterisk_equal,
        // asterisk_asterisk,
        // asterisk_percent,
        // asterisk_percent_equal,
        // asterisk_pipe,
        // asterisk_pipe_equal,
        // arrow,
        // colon,
        slash,
        // slash_equal,
        comma,
        // ampersand,
        // ampersand_equal,
        // question_mark,
        @"<",
        @"<=",
        @">",
        @">=",
        // tilde,
        number_literal,
        // doc_comment,
        // container_doc_comment,
        keyword_break,
        keyword_continue,
        keyword_fn,
        keyword_if,
        keyword_new,
        keyword_var,
        keyword_loop,
        keyword_yield,
    };
    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        // .{ "and", .keyword_and },
        .{ "break", .keyword_break },
        // .{ "catch", .keyword_catch },
        // .{ "const", .keyword_const },
        .{ "continue", .keyword_continue },
        // .{ "defer", .keyword_defer },
        // .{ "else", .keyword_else },
        // .{ "enum", .keyword_enum },
        // .{ "errdefer", .keyword_errdefer },
        // .{ "error", .keyword_error },
        // .{ "export", .keyword_export },
        // .{ "extern", .keyword_extern },
        .{ "fn", .keyword_fn },
        // .{ "for", .keyword_for },
        .{ "if", .keyword_if },
        // .{ "inline", .keyword_inline },
        .{ "loop", .keyword_loop },
        .{ "new", .keyword_new },
        // .{ "noalias", .keyword_noalias },
        // .{ "noinline", .keyword_noinline },
        // .{ "nosuspend", .keyword_nosuspend },
        // .{ "opaque", .keyword_opaque },
        // .{ "or", .keyword_or },
        // .{ "orelse", .keyword_orelse },
        // .{ "packed", .keyword_packed },
        // .{ "pub", .keyword_pub },
        // .{ "resume", .keyword_resume },
        // .{ "return", .keyword_return },
        // .{ "linksection", .keyword_linksection },
        // .{ "struct", .keyword_struct },
        // .{ "suspend", .keyword_suspend },
        // .{ "switch", .keyword_switch },
        // .{ "test", .keyword_test },
        // .{ "threadlocal", .keyword_threadlocal },
        // .{ "try", .keyword_try },
        // .{ "union", .keyword_union },
        // .{ "unreachable", .keyword_unreachable },
        .{ "var", .keyword_var },
        // .{ "volatile", .keyword_volatile },
        // .{ "while", .keyword_while },
        .{ "yield", .keyword_yield },
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
            .keyword_var => try writer.writeAll("the 'var' keyword"),
            .keyword_yield => try writer.writeAll("the 'yield' keyword"),
        }
    }
};

fn lex(text: []const u8, lex_start: usize) Token {
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
            .int => |start| .{ .tag = .number_literal, .start = start, .end = index },
            .angle_bracket_left => |start| .{ .tag = .@"<", .start = start, .end = index },
            .angle_bracket_right => |start| .{ .tag = .@">", .start = start, .end = index },
        };
        switch (state) {
            .start => {
                // index += 1;
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
                    // ';' => {
                    //     result.tag = .semicolon;
                    //     self.index += 1;
                    // },
                    ',' => return .{ .tag = .comma, .start = index, .end = index + 1 },
                    // '?' => {
                    //     result.tag = .question_mark;
                    //     self.index += 1;
                    // },
                    // ':' => {
                    //     result.tag = .colon;
                    //     self.index += 1;
                    // },
                    // '%' => continue :state .percent,
                    // '*' => continue :state .asterisk,
                    '+' => return .{ .tag = .plus, .start = index, .end = index + 1 },
                    '<' => {
                        state = .{ .angle_bracket_left = index };
                        index += 1;
                    },
                    '>' => {
                        state = .{ .angle_bracket_right = index };
                        index += 1;
                    },
                    // '^' => continue :state .caret,
                    // '\\' => {
                    //     result.tag = .multiline_string_literal_line;
                    //     continue :state .backslash;
                    // },
                    '{' => return .{ .tag = .l_brace, .start = index, .end = index + 1 },
                    '}' => return .{ .tag = .r_brace, .start = index, .end = index + 1 },
                    // '~' => {
                    //     result.tag = .tilde;
                    //     self.index += 1;
                    // },
                    '.' => return .{ .tag = .period, .start = index, .end = index + 1 },
                    // '-' => continue :state .minus,
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
                    '"' => {
                        @panic("todo");
                        // result.tag = .identifier;
                        // continue :state .string_literal;
                    },
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
                // '\\' => continue :state .string_literal_backslash,
                // '"' => self.index += 1,
                // 0x01...0x09, 0x0b...0x1f, 0x7f => {
                //     continue :state .invalid;
                // },
                // else => continue :state .string_literal,
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

    // state: switch (State.start) {
    //     .start => switch (self.buffer[self.index]) {
    //         0 => {
    //             if (self.index == self.buffer.len) {
    //                 return .{
    //                     .tag = .eof,
    //
    //                         .start = self.index,
    //                         .end = self.index,
    //                     },
    //                 };
    //             } else {
    //                 continue :state .invalid;
    //             }
    //         },
    //         ' ', '\n', '\t', '\r' => {
    //             self.index += 1;
    //             result.start = self.index;
    //             continue :state .start;
    //         },
    //         '"' => {
    //             result.tag = .string_literal;
    //             continue :state .string_literal;
    //         },
    //         '\'' => {
    //             result.tag = .char_literal;
    //             continue :state .char_literal;
    //         },
    //         'a'...'z', 'A'...'Z', '_' => {
    //             result.tag = .identifier;
    //             continue :state .identifier;
    //         },
    //         '@' => continue :state .saw_at_sign,
    //         '=' => continue :state .equal,
    //         '!' => continue :state .bang,
    //         '|' => continue :state .pipe,
    //         '(' => {
    //             result.tag = .l_paren;
    //             self.index += 1;
    //         },
    //         ')' => {
    //             result.tag = .r_paren;
    //             self.index += 1;
    //         },
    //         '[' => {
    //             result.tag = .l_bracket;
    //             self.index += 1;
    //         },
    //         ']' => {
    //             result.tag = .r_bracket;
    //             self.index += 1;
    //         },
    //         ';' => {
    //             result.tag = .semicolon;
    //             self.index += 1;
    //         },
    //         ',' => {
    //             result.tag = .comma;
    //             self.index += 1;
    //         },
    //         '?' => {
    //             result.tag = .question_mark;
    //             self.index += 1;
    //         },
    //         ':' => {
    //             result.tag = .colon;
    //             self.index += 1;
    //         },
    //         '%' => continue :state .percent,
    //         '*' => continue :state .asterisk,
    //         '+' => continue :state .plus,
    //         '<' => continue :state .angle_bracket_left,
    //         '>' => continue :state .angle_bracket_right,
    //         '^' => continue :state .caret,
    //         '\\' => {
    //             result.tag = .multiline_string_literal_line;
    //             continue :state .backslash;
    //         },
    //         '{' => {
    //             result.tag = .l_brace;
    //             self.index += 1;
    //         },
    //         '}' => {
    //             result.tag = .r_brace;
    //             self.index += 1;
    //         },
    //         '~' => {
    //             result.tag = .tilde;
    //             self.index += 1;
    //         },
    //         '.' => continue :state .period,
    //         '-' => continue :state .minus,
    //         '/' => continue :state .slash,
    //         '&' => continue :state .ampersand,
    //         '0'...'9' => {
    //             result.tag = .number_literal;
    //             self.index += 1;
    //             continue :state .int;
    //         },
    //         else => continue :state .invalid,
    //     },

    //     .expect_newline => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => {
    //                 if (self.index == self.buffer.len) {
    //                     result.tag = .invalid;
    //                 } else {
    //                     continue :state .invalid;
    //                 }
    //             },
    //             '\n' => {
    //                 self.index += 1;
    //                 result.start = self.index;
    //                 continue :state .start;
    //             },
    //             else => continue :state .invalid,
    //         }
    //     },

    //     .invalid => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => if (self.index == self.buffer.len) {
    //                 result.tag = .invalid;
    //             } else {
    //                 continue :state .invalid;
    //             },
    //             '\n' => result.tag = .invalid,
    //             else => continue :state .invalid,
    //         }
    //     },

    //     .saw_at_sign => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0, '\n' => result.tag = .invalid,
    //             '"' => {
    //                 result.tag = .identifier;
    //                 continue :state .string_literal;
    //             },
    //             'a'...'z', 'A'...'Z', '_' => {
    //                 result.tag = .builtin;
    //                 continue :state .builtin;
    //             },
    //             else => continue :state .invalid,
    //         }
    //     },

    //     .ampersand => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .ampersand_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .ampersand,
    //         }
    //     },

    //     .asterisk => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .asterisk_equal;
    //                 self.index += 1;
    //             },
    //             '*' => {
    //                 result.tag = .asterisk_asterisk;
    //                 self.index += 1;
    //             },
    //             '%' => continue :state .asterisk_percent,
    //             '|' => continue :state .asterisk_pipe,
    //             else => result.tag = .asterisk,
    //         }
    //     },

    //     .asterisk_percent => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .asterisk_percent_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .asterisk_percent,
    //         }
    //     },

    //     .asterisk_pipe => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .asterisk_pipe_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .asterisk_pipe,
    //         }
    //     },

    //     .percent => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .percent_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .percent,
    //         }
    //     },

    //     .plus => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .plus_equal;
    //                 self.index += 1;
    //             },
    //             '+' => {
    //                 result.tag = .plus_plus;
    //                 self.index += 1;
    //             },
    //             '%' => continue :state .plus_percent,
    //             '|' => continue :state .plus_pipe,
    //             else => result.tag = .plus,
    //         }
    //     },

    //     .plus_percent => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .plus_percent_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .plus_percent,
    //         }
    //     },

    //     .plus_pipe => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .plus_pipe_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .plus_pipe,
    //         }
    //     },

    //     .caret => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .caret_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .caret,
    //         }
    //     },

    //     .identifier => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
    //             else => {
    //                 const ident = self.buffer[result.start..self.index];
    //                 if (Token.getKeyword(ident)) |tag| {
    //                     result.tag = tag;
    //                 }
    //             },
    //         }
    //     },
    //     .builtin => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .builtin,
    //             else => {},
    //         }
    //     },
    //     .backslash => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => result.tag = .invalid,
    //             '\\' => continue :state .multiline_string_literal_line,
    //             '\n' => result.tag = .invalid,
    //             else => continue :state .invalid,
    //         }
    //     },
    //     .string_literal => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => {
    //                 if (self.index != self.buffer.len) {
    //                     continue :state .invalid;
    //                 } else {
    //                     result.tag = .invalid;
    //                 }
    //             },
    //             '\n' => result.tag = .invalid,
    //             '\\' => continue :state .string_literal_backslash,
    //             '"' => self.index += 1,
    //             0x01...0x09, 0x0b...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => continue :state .string_literal,
    //         }
    //     },

    //     .string_literal_backslash => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0, '\n' => result.tag = .invalid,
    //             else => continue :state .string_literal,
    //         }
    //     },

    //     .char_literal => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => {
    //                 if (self.index != self.buffer.len) {
    //                     continue :state .invalid;
    //                 } else {
    //                     result.tag = .invalid;
    //                 }
    //             },
    //             '\n' => result.tag = .invalid,
    //             '\\' => continue :state .char_literal_backslash,
    //             '\'' => self.index += 1,
    //             0x01...0x09, 0x0b...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => continue :state .char_literal,
    //         }
    //     },

    //     .char_literal_backslash => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => {
    //                 if (self.index != self.buffer.len) {
    //                     continue :state .invalid;
    //                 } else {
    //                     result.tag = .invalid;
    //                 }
    //             },
    //             '\n' => result.tag = .invalid,
    //             0x01...0x09, 0x0b...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => continue :state .char_literal,
    //         }
    //     },

    //     .multiline_string_literal_line => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => if (self.index != self.buffer.len) {
    //                 continue :state .invalid;
    //             },
    //             '\n' => {},
    //             '\r' => if (self.buffer[self.index + 1] != '\n') {
    //                 continue :state .invalid;
    //             },
    //             0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
    //             else => continue :state .multiline_string_literal_line,
    //         }
    //     },

    //     .bang => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .bang_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .bang,
    //         }
    //     },

    //     .pipe => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .pipe_equal;
    //                 self.index += 1;
    //             },
    //             '|' => {
    //                 result.tag = .pipe_pipe;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .pipe,
    //         }
    //     },

    //     .equal => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .equal_equal;
    //                 self.index += 1;
    //             },
    //             '>' => {
    //                 result.tag = .equal_angle_bracket_right;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .equal,
    //         }
    //     },

    //     .minus => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '>' => {
    //                 result.tag = .arrow;
    //                 self.index += 1;
    //             },
    //             '=' => {
    //                 result.tag = .minus_equal;
    //                 self.index += 1;
    //             },
    //             '%' => continue :state .minus_percent,
    //             '|' => continue :state .minus_pipe,
    //             else => result.tag = .minus,
    //         }
    //     },

    //     .minus_percent => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .minus_percent_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .minus_percent,
    //         }
    //     },
    //     .minus_pipe => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .minus_pipe_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .minus_pipe,
    //         }
    //     },

    //     .angle_bracket_left => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '<' => continue :state .angle_bracket_angle_bracket_left,
    //             '=' => {
    //                 result.tag = .angle_bracket_left_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .angle_bracket_left,
    //         }
    //     },

    //     .angle_bracket_angle_bracket_left => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .angle_bracket_angle_bracket_left_equal;
    //                 self.index += 1;
    //             },
    //             '|' => continue :state .angle_bracket_angle_bracket_left_pipe,
    //             else => result.tag = .angle_bracket_angle_bracket_left,
    //         }
    //     },

    //     .angle_bracket_angle_bracket_left_pipe => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .angle_bracket_angle_bracket_left_pipe_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .angle_bracket_angle_bracket_left_pipe,
    //         }
    //     },

    //     .angle_bracket_right => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '>' => continue :state .angle_bracket_angle_bracket_right,
    //             '=' => {
    //                 result.tag = .angle_bracket_right_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .angle_bracket_right,
    //         }
    //     },

    //     .angle_bracket_angle_bracket_right => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '=' => {
    //                 result.tag = .angle_bracket_angle_bracket_right_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .angle_bracket_angle_bracket_right,
    //         }
    //     },

    //     .period => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '.' => continue :state .period_2,
    //             '*' => continue :state .period_asterisk,
    //             else => result.tag = .period,
    //         }
    //     },

    //     .period_2 => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '.' => {
    //                 result.tag = .ellipsis3;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .ellipsis2,
    //         }
    //     },

    //     .period_asterisk => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '*' => result.tag = .invalid_periodasterisks,
    //             else => result.tag = .period_asterisk,
    //         }
    //     },

    //     .slash => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '/' => continue :state .line_comment_start,
    //             '=' => {
    //                 result.tag = .slash_equal;
    //                 self.index += 1;
    //             },
    //             else => result.tag = .slash,
    //         }
    //     },
    //     .line_comment_start => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => {
    //                 if (self.index != self.buffer.len) {
    //                     continue :state .invalid;
    //                 } else return .{
    //                     .tag = .eof,
    //
    //                         .start = self.index,
    //                         .end = self.index,
    //                     },
    //                 };
    //             },
    //             '!' => {
    //                 result.tag = .container_doc_comment;
    //                 continue :state .doc_comment;
    //             },
    //             '\n' => {
    //                 self.index += 1;
    //                 result.start = self.index;
    //                 continue :state .start;
    //             },
    //             '/' => continue :state .doc_comment_start,
    //             '\r' => continue :state .expect_newline,
    //             0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => continue :state .line_comment,
    //         }
    //     },
    //     .doc_comment_start => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0, '\n' => result.tag = .doc_comment,
    //             '\r' => {
    //                 if (self.buffer[self.index + 1] == '\n') {
    //                     result.tag = .doc_comment;
    //                 } else {
    //                     continue :state .invalid;
    //                 }
    //             },
    //             '/' => continue :state .line_comment,
    //             0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => {
    //                 result.tag = .doc_comment;
    //                 continue :state .doc_comment;
    //             },
    //         }
    //     },
    //     .line_comment => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0 => {
    //                 if (self.index != self.buffer.len) {
    //                     continue :state .invalid;
    //                 } else return .{
    //                     .tag = .eof,
    //
    //                         .start = self.index,
    //                         .end = self.index,
    //                     },
    //                 };
    //             },
    //             '\n' => {
    //                 self.index += 1;
    //                 result.start = self.index;
    //                 continue :state .start;
    //             },
    //             '\r' => continue :state .expect_newline,
    //             0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => continue :state .line_comment,
    //         }
    //     },
    //     .doc_comment => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             0, '\n' => {},
    //             '\r' => if (self.buffer[self.index + 1] != '\n') {
    //                 continue :state .invalid;
    //             },
    //             0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
    //                 continue :state .invalid;
    //             },
    //             else => continue :state .doc_comment,
    //         }
    //     },
    //     .int => switch (self.buffer[self.index]) {
    //         '.' => continue :state .int_period,
    //         '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
    //             self.index += 1;
    //             continue :state .int;
    //         },
    //         'e', 'E', 'p', 'P' => {
    //             continue :state .int_exponent;
    //         },
    //         else => {},
    //     },
    //     .int_exponent => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '-', '+' => {
    //                 self.index += 1;
    //                 continue :state .float;
    //             },
    //             else => continue :state .int,
    //         }
    //     },
    //     .int_period => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
    //                 self.index += 1;
    //                 continue :state .float;
    //             },
    //             'e', 'E', 'p', 'P' => {
    //                 continue :state .float_exponent;
    //             },
    //             else => self.index -= 1,
    //         }
    //     },
    //     .float => switch (self.buffer[self.index]) {
    //         '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
    //             self.index += 1;
    //             continue :state .float;
    //         },
    //         'e', 'E', 'p', 'P' => {
    //             continue :state .float_exponent;
    //         },
    //         else => {},
    //     },
    //     .float_exponent => {
    //         self.index += 1;
    //         switch (self.buffer[self.index]) {
    //             '-', '+' => {
    //                 self.index += 1;
    //                 continue :state .float;
    //             },
    //             else => continue :state .float,
    //         }
    //     },
    // }

    // result.end = self.index;
    // return result;
}

const TokenIterator = struct {
    text: []const u8,
    offset: usize = 0,
    pub fn next(it: *TokenIterator) Token {
        const token = lex(it.text, it.offset);
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

const MethodNameKind = enum { id, new };

pub const Error = union(enum) {
    not_implemented: [:0]const u8,
    log_error: struct {
        pos: usize,
        err: std.fs.File.WriteError,
    },
    unexpected_token: struct { expected: [:0]const u8, token: Token },
    unexpected_type: struct {
        pos: usize,
        expected: [:0]const u8,
        actual: ?Type,
    },
    unknown_builtin: Token,
    undefined_identifier: Extent,
    num_literal_overflow: Extent,
    bad_num_literal: Extent,
    called_non_function: struct {
        start: usize,
        unexpected_type: ?Type,
    },
    void_field: struct { start: usize },
    no_field: struct {
        start: usize,
        field: Extent,
        unexpected_type: Type,
    },
    too_many_assembly_fields: struct {
        pos: usize,
    },
    arg_count: struct {
        start: usize,
        expected: u16,
        actual: u17,
    },
    arg_type: struct {
        arg_pos: usize,
        arg_index: u16,
        expected: Type,
        actual: Type,
    },
    arg_type_call_pos: struct {
        call_pos: usize,
        arg_index: u16,
        expected: Type,
        actual: Type,
    },
    new_non_class: struct {
        id_extent: Extent,
        actual_type: Type,
    },
    statement_result_ignored: struct {
        pos: usize,
        ignored_type: Type,
    },
    // an identifier was assigned a void value
    void_assignment: struct {
        id_extent: Extent,
    },
    assign_type: struct {
        id_extent: Extent,
        dst: Type,
        src: Type,
    },
    void_argument: struct {
        arg_index: u32,
        first_arg_token: Token,
    },
    assembly_not_found: Extent,
    id_too_big: Extent,
    missing_class: struct {
        assembly: *const mono.Assembly,
        id_start: usize,
    },
    missing_method: struct {
        class: *const mono.Class,
        id_extent: Extent,
        arg_count: u16,
    },
    new_failed: struct {
        pos: usize,
        class: *const mono.Class,
    },
    cant_marshal: struct {
        pos: usize,
        type: Type,
    },
    binary_operand_nothing: struct {
        pos: usize,
        op: BinaryOp,
    },
    binary_operand_type: struct {
        pos: usize,
        op: BinaryOp,
        expects: [:0]const u8,
        actual: Type,
    },
    overflow_i64: struct {
        pos: usize,
        op: BinaryOp,
        left_i64: i64,
        right_i64: i64,
    },
    divide_by_0: struct {
        pos: usize,
    },
    if_type: struct { pos: usize, type: ?Type },
    static_error: struct {
        pos: usize,
        string: [:0]const u8,
    },
    oom,
    pub fn set(err: *Error, value: Error) error{Vm} {
        err.* = value;
        return error.Vm;
    }
    pub fn setOom(err: *Error, e: error{OutOfMemory}) error{Vm} {
        e catch {};
        err.* = .oom;
        return error.Vm;
    }
    pub fn fmt(err: *const Error, text: []const u8) ErrorFmt {
        return .{ .err = err, .text = text };
    }
};
const ErrorFmt = struct {
    err: *const Error,
    text: []const u8,
    pub fn format(f: *const ErrorFmt, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (f.err.*) {
            .not_implemented => |n| try writer.print("{s} not implemented", .{n}),
            .log_error => |e| try writer.print(
                "{d}: @Log failed with {t}",
                .{ getLineNum(f.text, e.pos), e.err },
            ),
            .unexpected_token => |e| try writer.print(
                "{d}: syntax error: expected {s} but got {f}",
                .{
                    getLineNum(f.text, e.token.start),
                    e.expected,
                    e.token.fmt(f.text),
                },
            ),
            .unexpected_type => |e| try writer.print(
                "{d}: expected {s} but got {s}",
                .{
                    getLineNum(f.text, e.pos),
                    e.expected,
                    if (e.actual) |t| t.what() else "nothing",
                },
            ),
            .unknown_builtin => |token| try writer.print(
                "{d}: unknown builtin '{s}'",
                .{
                    getLineNum(f.text, token.start),
                    f.text[token.start..token.end],
                },
            ),
            .undefined_identifier => |token| try writer.print(
                "{d}: undefined identifier '{s}'",
                .{
                    getLineNum(f.text, token.start),
                    f.text[token.start..token.end],
                },
            ),
            .num_literal_overflow => |e| try writer.print(
                "{d}: integer literal '{s}' doesn't fit in an i64",
                .{ getLineNum(f.text, e.start), f.text[e.start..e.end] },
            ),
            .bad_num_literal => |e| try writer.print(
                "{d}: invalid integer literal '{s}'",
                .{ getLineNum(f.text, e.start), f.text[e.start..e.end] },
            ),
            .called_non_function => |e| if (e.unexpected_type) |t| switch (t) {
                .assembly_field => try writer.print("{d}: can't call fields on an assembly directly, call @Class first", .{getLineNum(f.text, e.start)}),
                else => try writer.print(
                    "{d}: can't call {s}",
                    .{ getLineNum(f.text, e.start), t.what() },
                ),
            } else try writer.print(
                "{d}: attempted to call a void expression",
                .{getLineNum(f.text, e.start)},
            ),
            .void_field => |e| try writer.print(
                "{d}: void has no fields",
                .{getLineNum(f.text, e.start)},
            ),
            .no_field => |e| try writer.print(
                "{d}: {s} has no field '{s}'",
                .{
                    getLineNum(f.text, e.start),
                    e.unexpected_type.what(),
                    f.text[e.field.start..e.field.end],
                },
            ),
            .too_many_assembly_fields => |t| try writer.print(
                "{d}: too many assembly fields",
                .{getLineNum(f.text, t.pos)},
            ),
            .arg_count => |e| try writer.print("{d}: expected {} args but got {}", .{
                getLineNum(f.text, e.start),
                e.expected,
                e.actual,
            }),
            .arg_type => |e| try writer.print("{d}: expected argument {} to be {s} but got {s}", .{
                getLineNum(f.text, e.arg_pos),
                e.arg_index,
                e.expected.what(),
                e.actual.what(),
            }),
            .arg_type_call_pos => |e| try writer.print("{d}: expected argument {} to be {s} but got {s}", .{
                getLineNum(f.text, e.call_pos),
                e.arg_index,
                e.expected.what(),
                e.actual.what(),
            }),
            .new_non_class => |n| try writer.print(
                "{d}: cannot new '{s}' which is {s}",
                .{
                    getLineNum(f.text, n.id_extent.start),
                    f.text[n.id_extent.start..n.id_extent.end],
                    n.actual_type.what(),
                },
            ),
            .statement_result_ignored => |i| try writer.print(
                "{d}: return value of type {t} was ignored, use @Discard to discard it",
                .{ getLineNum(f.text, i.pos), i.ignored_type },
            ),
            .void_assignment => |v| try writer.print(
                "{d}: nothing was assigned to identifier '{s}'",
                .{
                    getLineNum(f.text, v.id_extent.start),
                    f.text[v.id_extent.start..v.id_extent.end],
                },
            ),
            .assign_type => |e| try writer.print(
                "{d}: cannot assign {s} to identifier '{s}' which is {s}",
                .{
                    getLineNum(f.text, e.id_extent.start),
                    e.src.what(),
                    f.text[e.id_extent.start..e.id_extent.end],
                    e.dst.what(),
                },
            ),
            .void_argument => |v| try writer.print(
                "{d}: nothing was assigned function argument {}",
                .{
                    getLineNum(f.text, v.first_arg_token.start),
                    v.arg_index + 1,
                },
            ),
            .assembly_not_found => |extent| try writer.print(
                "{d}: assembly {s} not found",
                .{
                    getLineNum(f.text, extent.start),
                    f.text[extent.start..extent.end],
                },
            ),
            .id_too_big => |token| try writer.print(
                "{d}: id '{s}' is too big ({} bytes but max is {})",
                .{
                    getLineNum(f.text, token.start),
                    f.text[token.start..token.end],
                    token.end - token.start,
                    ManagedId.max,
                },
            ),
            .missing_class => |m| {
                // if we got a missing_class error, it means the namespace/name
                // can be lexed
                var namespace: ManagedId = .empty();
                var name: ManagedId = .empty();
                _ = lexClass(f.text, &namespace, &name, m.id_start);
                try writer.print(
                    "{d}: this assembly does not have a class named {s} in namespace {s}",
                    .{
                        getLineNum(f.text, m.id_start),
                        name.slice(),
                        namespace.slice(),
                    },
                );
            },
            .missing_method => |m| try writer.print(
                "{d}: method {s} with {} params does not exist in this class",
                .{
                    getLineNum(f.text, m.id_extent.start),
                    f.text[m.id_extent.start..m.id_extent.end],
                    m.arg_count,
                },
            ),
            .new_failed => |n| try writer.print("{d}: new failed", .{
                getLineNum(f.text, n.pos),
            }),
            .cant_marshal => |c| try writer.print(
                "{d}: can't marshal {s} to a managed method",
                .{ getLineNum(f.text, c.pos), c.type.what() },
            ),
            .binary_operand_nothing => |e| try writer.print(
                "{d}: one side of binary operation '{t}' is nothing",
                .{ getLineNum(f.text, e.pos), e.op },
            ),
            .binary_operand_type => |e| try writer.print(
                "{d}: binary operation '{t}' expects {s} but got {s}",
                .{
                    getLineNum(f.text, e.pos),
                    e.op,
                    e.expects,
                    e.actual.what(),
                },
            ),
            .overflow_i64 => |o| try writer.print(
                "{d}: i64 overflow from '{t}' operator on {} and {}",
                .{
                    getLineNum(f.text, o.pos),
                    o.op,
                    o.left_i64,
                    o.right_i64,
                },
            ),
            .divide_by_0 => |d| try writer.print("{d}: divide by 0", .{getLineNum(f.text, d.pos)}),
            .if_type => |e| if (e.type) |t| try writer.print(
                "{d}: if requires an integer but got {s}",
                .{ getLineNum(f.text, e.pos), t.what() },
            ) else try writer.print(
                "{d}: if conditional expression resulted in nothing",
                .{getLineNum(f.text, e.pos)},
            ),
            .static_error => |e| try writer.print(
                "{d}: {s}",
                .{ getLineNum(f.text, e.pos), e.string },
            ),
            .oom => try writer.writeAll("out of memory"),
        }
    }
};

pub fn runTests(mono_funcs: *const mono.Funcs) !void {
    try badCodeTests(mono_funcs);
    try goodCodeTests(mono_funcs);
}

test {
    try badCodeTests(&monomock.funcs);
    try goodCodeTests(&monomock.funcs);
}

fn testBadCode(mono_funcs: *const mono.Funcs, text: []const u8, expected_error: []const u8) !void {
    std.debug.print("testing bad code:\n---\n{s}\n---\n", .{text});

    var test_domain: TestDomain = undefined;
    test_domain.init(mono_funcs);
    defer test_domain.deinit(mono_funcs);

    var buffer: [4096 * 2]u8 = undefined;
    std.debug.assert(buffer.len >= std.heap.pageSize());
    var vm_fixed_fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var vm: Vm = .{
        .mono_funcs = mono_funcs,
        .text = text,
        .mem = .{ .allocator = vm_fixed_fba.allocator() },
    };
    defer {
        // vm.logStack();
        // vm.verifyStack();
        vm.deinit();
    }
    var block_resume: BlockResume = .{};
    while (true) {
        vm.verifyStack();
        const yield = vm.evalRoot(block_resume) catch switch (vm.error_result) {
            .exit => return error.TestUnexpectedSuccess,
            .err => |err| {
                var buf: [2000]u8 = undefined;
                const actual_error = try std.fmt.bufPrint(&buf, "{f}", .{err.fmt(text)});
                if (!std.mem.eql(u8, expected_error, actual_error)) {
                    std.log.err("actual error string\n\"{f}\"\n", .{std.zig.fmtString(actual_error)});
                    return error.TestUnexpectedError;
                }
                break;
            },
        };
        block_resume = yield.block_resume;
    }
}

fn badCodeTests(mono_funcs: *const mono.Funcs) !void {
    try testBadCode(mono_funcs, "var example_id = @Nothing()", "1: nothing was assigned to identifier 'example_id'");
    try testBadCode(mono_funcs, "@Nothing", "1: syntax error: expected a '(' to start the builtin args but got EOF");
    try testBadCode(mono_funcs, "fn", "1: syntax error: expected an identifier after 'fn' but got EOF");
    try testBadCode(mono_funcs, "fn @Nothing()", "1: syntax error: expected an identifier after 'fn' but got the builtin function '@Nothing'");
    try testBadCode(mono_funcs, "fn foo", "1: syntax error: expected an open paren '(' to start function args but got EOF");
    try testBadCode(mono_funcs, "fn foo \"hello\"", "1: syntax error: expected an open paren '(' to start function args but got a string literal \"hello\"");
    try testBadCode(mono_funcs, "fn foo )", "1: syntax error: expected an open paren '(' to start function args but got a close paren ')'");
    try testBadCode(mono_funcs, "foo()", "1: undefined identifier 'foo'");
    try testBadCode(mono_funcs, "var foo = \"hello\" foo()", "1: can't call a string literal");
    try testBadCode(mono_funcs, "@Assembly(\"wontbefound\")", "1: assembly \"wontbefound\" not found");
    try testBadCode(mono_funcs, "var mscorlib = @Assembly(\"mscorlib\") mscorlib()", "1: can't call an assembly");
    try testBadCode(mono_funcs, "fn foo(){}foo.\"wat\"", "1: syntax error: expected an identifier after '.' but got a string literal \"wat\"");
    try testBadCode(mono_funcs, "@Nothing().foo", "1: void has no fields");
    try testBadCode(mono_funcs, "fn foo(){}foo.wat", "1: a function has no field 'wat'");
    try testBadCode(mono_funcs, "@Assembly(\"mscorlib\")()", "1: can't call an assembly");
    try testBadCode(
        mono_funcs,
        "@Class(@Assembly(\"mscorlib\")." ++ ("a" ** (ManagedId.max + 1)) ++ ")",
        "1: id '" ++ ("a" ** (ManagedId.max + 1)) ++ "' is too big (1024 bytes but max is 1023)",
    );
    try testBadCode(mono_funcs, "@Class(@Assembly(\"mscorlib\").DoesNot.Exist)", "1: this assembly does not have a class named Exist in namespace DoesNot");
    try testBadCode(mono_funcs, "999999999999999999999", "1: integer literal '999999999999999999999' doesn't fit in an i64");
    // try testBadCode(mono_funcs, "-999999999999999999999", "1: integer literal '-999999999999999999999' doesn't fit in an i64");
    // const max_fields = 256;
    // try testCode("@Assembly(\"mscorlib\")" ++ (".a" ** max_fields));
    // try testBadCode(mono_funcs, "@Assembly(\"mscorlib\")" ++ (".a" ** (max_fields + 1)), "1: too many assembly fields");

    // try testBadCode(mono_funcs, "new", "1: syntax error: expected an identifier to follow 'new' but got EOF");
    // try testBadCode(mono_funcs, "new 0", "1: syntax error: expected an identifier to follow 'new' but got a number literal 0");
    // try testBadCode(mono_funcs, "new foo(", "");
    // try testBadCode(mono_funcs, "new foo()", "1: undefined identifier 'foo'");
    // try testBadCode(mono_funcs, "foo=0 new foo()", "1: cannot new 'foo' which is an integer");

    try testBadCode(mono_funcs, "0n", "1: invalid integer literal '0n'");

    try testBadCode(mono_funcs, "fn a(", "1: syntax error: expected an identifier or close paren ')' but got EOF");
    try testBadCode(mono_funcs, "fn a(0){}", "1: syntax error: expected an identifier or close paren ')' but got a number literal 0");
    try testBadCode(mono_funcs, "fn a(\"hey\"){}", "1: syntax error: expected an identifier or close paren ')' but got a string literal \"hey\"");

    try testBadCode(mono_funcs, "fn a(){} a(0)", "1: expected 0 args but got 1");
    try testBadCode(mono_funcs, "fn a(x){} a()", "1: expected 1 args but got 0");
    try testBadCode(mono_funcs, "@Assembly(\"mscorlib\").foo()", "1: can't call fields on an assembly directly, call @Class first");
    try testBadCode(mono_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Console = @Class(mscorlib.System.Console)
        \\fn foo() {}
        \\Console.Write(foo);
    , "4: can't marshal a function to a managed method");
    try testBadCode(mono_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Console = @Class(mscorlib.System.Console)
        \\Console.ThisMethodShouldNotExist();
    , "3: method ThisMethodShouldNotExist with 0 params does not exist in this class");
    try testBadCode(mono_funcs, "0", "1: return value of type integer was ignored, use @Discard to discard it");
    try testBadCode(mono_funcs, "\"hello\"", "1: return value of type string_literal was ignored, use @Discard to discard it");
    try testBadCode(mono_funcs, "(", "1: syntax error: expected an expression after '(' but got EOF");
    try testBadCode(mono_funcs, "(0", "1: syntax error: expected a close paren ')' to end expression but got EOF");
    try testBadCode(mono_funcs, "0+@Nothing()", "1: one side of binary operation '+' is nothing");
    try testBadCode(mono_funcs, "@Nothing()+0", "1: one side of binary operation '+' is nothing");
    try testBadCode(mono_funcs, "0+\"hello\"", "1: binary operation '+' expects integers but got a string literal");
    try testBadCode(mono_funcs, "\"hello\"+0", "1: binary operation '+' expects integers but got a string literal");
    try testBadCode(mono_funcs, "0/0", "1: divide by 0");
    try testBadCode(mono_funcs, "1/0", "1: divide by 0");
    try testCode(mono_funcs, "@Log(9_223_372_036_854_775_807+0)");
    try testBadCode(mono_funcs, "9_223_372_036_854_775_807+1", "1: i64 overflow from '+' operator on 9223372036854775807 and 1");
    try testBadCode(mono_funcs, "foo=0", "1: undefined identifier 'foo'");
    try testBadCode(mono_funcs, "fn foo(){}foo=0", "1: cannot assign an integer to identifier 'foo' which is a function");
    try testBadCode(mono_funcs, "var foo = \"hello\" foo=0", "1: cannot assign an integer to identifier 'foo' which is a string literal");
    try testBadCode(mono_funcs, "if", "1: syntax error: expected a '(' to start the if conditional but got EOF");
    try testBadCode(mono_funcs, "if()", "1: syntax error: expected an expression inside the if conditional but got a close paren ')'");
    try testBadCode(mono_funcs, "if(0", "1: syntax error: expected a ')' to finish the if conditional but got EOF");
    try testBadCode(mono_funcs, "if(@Nothing())", "1: if conditional expression resulted in nothing");
    try testBadCode(mono_funcs, "if(\"hello\")", "1: if requires an integer but got a string literal");
    try testBadCode(mono_funcs, "if(0)", "1: syntax error: expected an open brace '{' to start if block but got EOF");
    try testBadCode(mono_funcs, "if(0){", "1: syntax error: expected a statement but got EOF");
    // try testBadCode(mono_funcs, "@ScheduleMs()", "1: @ScheduleMs requires at least 2 args (millisecond count and function id) but got 0");
    // try testBadCode(mono_funcs, "@ScheduleMs(\"hello\")", "1: expected argument 0 to be an integer but got a string literal");
    // try testBadCode(mono_funcs, "@ScheduleMs(0)", "1: @ScheduleMs requires at least 2 args (millisecond count and function id) but got 1");
    // try testBadCode(mono_funcs, "@ScheduleMs(0, 0)", "");
    try testBadCode(mono_funcs, "yield", "1: syntax error: expected an expression after yield but got EOF");
    try testBadCode(mono_funcs, "yield @Nothing()", "1: expected an integer expression after yield but got nothing");
    try testBadCode(mono_funcs, "yield \"hello\"", "1: expected an integer expression after yield but got a string literal");
    try testBadCode(mono_funcs, "loop loop", "1: cannot loop inside loop (end with break or continue at the same depth as the original loop)");
    try testBadCode(mono_funcs, "break", "1: break must correspond to a loop");
    try testBadCode(mono_funcs, "continue", "1: continue must correspond to a loop");
    try testBadCode(mono_funcs, "loop break break", "1: break must correspond to a loop");
    try testBadCode(mono_funcs, "loop break continue", "1: continue must correspond to a loop");
    try testBadCode(mono_funcs, "if (1) { break }", "1: break must correspond to a loop");
}

const TestDomain = struct {
    mock_domain: if (is_test) monomock.Domain else void,
    thread: *const mono.Thread,
    pub fn init(self: *TestDomain, mono_funcs: *const mono.Funcs) void {
        if (is_test) {
            if (mono_funcs == &monomock.funcs) {
                std.debug.assert(null == mono_funcs.domain_get());
                self.mock_domain = .{};
                monomock.setRootDomain(&self.mock_domain);
            }
        }

        const root_domain = mono_funcs.get_root_domain() orelse @panic(
            "mono_get_root_domain returned null",
        );
        self.thread = mono_funcs.thread_attach(root_domain) orelse @panic(
            "mono_thread_attach failed",
        );

        // domain_get is how the Vm accesses the domain, make sure it's
        // what we expect after attaching our thread to it
        std.debug.assert(mono_funcs.domain_get() == root_domain);
    }
    pub fn deinit(self: *TestDomain, mono_funcs: *const mono.Funcs) void {
        if (is_test) {
            if (mono_funcs == &monomock.funcs) {
                mono_funcs.thread_detach(self.thread);
                monomock.unsetRootDomain(&self.mock_domain);
                self.mock_domain.deinit();
            }
        }
        self.* = undefined;
    }
};

fn testCode(mono_funcs: *const mono.Funcs, text: []const u8) !void {
    std.debug.print("testing code:\n---\n{s}\n---\n", .{text});

    var test_domain: TestDomain = undefined;
    test_domain.init(mono_funcs);
    defer test_domain.deinit(mono_funcs);

    var buffer: [4096 * 2]u8 = undefined;
    std.debug.assert(buffer.len >= std.heap.pageSize());
    var vm_fixed_fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var vm: Vm = .{
        .mono_funcs = mono_funcs,
        .text = text,
        .mem = .{ .allocator = vm_fixed_fba.allocator() },
    };
    var block_resume: BlockResume = .{};
    while (true) {
        vm.verifyStack();
        const yield = vm.evalRoot(block_resume) catch switch (vm.error_result) {
            .exit => break,
            .err => |err| {
                std.debug.print(
                    "Failed to interpret the following code:\n---\n{s}\n---\nerror: {f}\n",
                    .{ text, err.fmt(text) },
                );
                return error.VmError;
            },
        };
        block_resume = yield.block_resume;
    }
    vm.logStack();
    vm.verifyStack();
    vm.deinit();
    // try std.testing.expectEqual(0, vm_fixed_fba.end_index);
}

fn goodCodeTests(mono_funcs: *const mono.Funcs) !void {
    try testCode(mono_funcs, "fn foo(){}");
    try testCode(mono_funcs, "@LogAssemblies()");
    try testCode(mono_funcs, "fn foo(){ @LogAssemblies() }");
    try testCode(mono_funcs, "fn foo(){ @LogAssemblies() }foo()foo()");
    try testCode(mono_funcs, "@Discard(0)");
    try testCode(mono_funcs, "@Discard(\"Hello\")");
    try testCode(mono_funcs, "@Discard(@Assembly(\"mscorlib\"))");
    try testCode(mono_funcs, "@Discard(@Assembly(\"mscorlib\").System)");
    try testCode(mono_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\@Discard(@Class(mscorlib.System.Object))
    );
    try testCode(mono_funcs, "var ms = @Assembly(\"mscorlib\")");
    try testCode(mono_funcs, "var foo_string = \"foo\"");
    try testCode(mono_funcs, "fn foo(){}@Discard(foo)");
    try testCode(mono_funcs, "fn foo(){}foo()");
    // try testCode(mono_funcs, "\"foo\"[0]");
    // try testCode(mono_funcs, "@Assembly(\"mscorlib\") =");
    try testCode(mono_funcs, "fn foo(x) { }");
    try testCode(mono_funcs, "var a = 0 a = 1 @Log(\"a is now \", a)");
    try testCode(mono_funcs, "var a = 0 a = 1234 @Log(\"a is now \", a)");
    // try testCode(mono_funcs, "fn foo(x) { }foo(0)");
    // try testCode(mono_funcs, "fn foo(x,y) { }foo(0,1)");
    if (false) try testCode(mono_funcs,
        \\fn fib(n) {
        \\  if (n <= 1) return n
        \\  return fib(n - 1) + fib(n - 1)
        \\}
        \\fib(10)
    );
    try testCode(mono_funcs, "@Log(0)");
    try testCode(mono_funcs, "@Log(\"Hello @Log!\")");
    try testCode(mono_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Environment = @Class(mscorlib.System.Environment)
        \\@Log(Environment.get_TickCount())
        \\@Log("TickCount: ", Environment.get_TickCount())
        \\//@Log(Environment.get_MachineName())
        \\fn foo(){} @Log(foo)
        \\@Log(mscorlib)
        \\@Log(mscorlib.Foo.Bar)
        \\@Log(Environment)
        \\@Log(Environment.Foo)
    );
    try testCode(mono_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Object = @Class(mscorlib.System.Object)
        \\//mscorlib.System.Console.WriteLine()
        \\//mscorlib.System.Console.Beep()
        \\//example_obj = new Object()
        \\
    );
    try testCode(mono_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Console = @Class(mscorlib.System.Console)
        \\Console.Beep()
        \\Console.WriteLine()
        \\//Console.WriteLine("Hello")
        \\var Environment = @Class(mscorlib.System.Environment)
        \\@Discard(Environment.get_TickCount())
        \\//@Discard(Environment.get_MachineName())
        \\
        \\//sys = @Assembly("System")
        \\//Stopwatch = @Class(sys.System.Diagnostics.Stopwatch)
    );
    try testCode(mono_funcs, "@Log((0))");
    try testCode(mono_funcs, "@Log(((0)))");
    try testCode(mono_funcs, "@Log(3+4)");
    try testCode(mono_funcs, "@Log(3/4)");
    try testCode(mono_funcs, "@Log(15/(1+4))");
    try testCode(mono_funcs, "@Log(0 == 0)");
    try testCode(mono_funcs, "@Log(0 != 0)");
    try testCode(mono_funcs, "@Log(0 < 0)");
    try testCode(mono_funcs, "@Log(0 > 0)");
    try testCode(mono_funcs, "@Log(0 <= 0)");
    try testCode(mono_funcs, "@Log(0 >= 0)");
    try testCode(mono_funcs, "@Log(0 == 0+1)");
    try testCode(mono_funcs, "@Log(0+1 == 0+1)");
    try testCode(mono_funcs, "if(0){}");
    try testCode(mono_funcs, "if(1){}");
    try testCode(mono_funcs, " if (0 > 1) { @Log(\"if statement!\") }");
    try testCode(mono_funcs, " if (0 < 1) { @Log(\"if statement!\") }");
    try testCode(mono_funcs, "yield 0");
    try testCode(mono_funcs, "loop");
    try testCode(mono_funcs, "loop break");
    try testCode(mono_funcs, "loop break loop");
    try testCode(mono_funcs, "loop if (1) { break }");
    try testCode(mono_funcs, "loop if (1) { break } break");
    try testCode(mono_funcs, "loop if (1) { break } continue");
    // TODO! make this work
    //try testCode(mono_funcs, "loop if (1) { break } continue");
    try testCode(mono_funcs,
        \\var counter = 0
        \\loop
        \\  @Log("default continue loop: ", counter)
        \\  yield 0
        \\  counter = counter + 1
        \\  if (counter == 5) { break }
        \\continue
    );
    if (false) try testCode(mono_funcs,
        \\var counter = 0
        \\loop
        \\  @Log("default break loop: ", counter)
        \\  yield 0
        \\  counter = counter + 1
        \\  if (counter < 5) { continue }
        \\break
    );
}

const is_test = @import("builtin").is_test;

const std = @import("std");
const mono = @import("mono.zig");
const monomock = if (is_test) @import("monomock.zig") else struct {};
const Memory = @import("Memory.zig");
