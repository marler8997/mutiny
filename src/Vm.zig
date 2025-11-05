const Vm = @This();

mono_funcs: *const mono.Funcs,
mono_domain: *mono.Domain,
err: Error,
text: []const u8,
mem: Memory,
symbols: std.SinglyLinkedList,

const Extent = struct { start: usize, end: usize };

const Symbol = struct {
    list_node: std.SinglyLinkedList.Node,
    extent: Extent,
    value_addr: Memory.Addr,
};
const Function = struct { id_extent: Extent };

const Value = union(enum) {
    type: ?Type,
    string_literal: Extent,
    assembly: *mono.Assembly,
    pub fn deinit(value: *Value) void {
        switch (value.*) {
            .type => {},
            .string_literal => {},
            .assembly => {},
        }
    }
    pub fn moveInto(value: *Value, dst: *Value) void {
        switch (value.*) {
            .type,
            .string_literal,
            .assembly,
            => {
                dst.* = value.*;
            },
        }
    }
    pub fn getType(value: *const Value) Type {
        return switch (value.*) {
            .type => .type,
            .string_literal => .string_literal,
            .assembly => .assembly,
        };
    }
};

const Type = enum {
    type,
    string_literal,
    assembly,
};

const max_load_assembly_string = 15;

const TypeContext = enum { @"return", param };

pub const Error = union(enum) {
    not_implemented: [:0]const u8,
    unexpected_token: struct { expected: [:0]const u8, token: Token },
    unknown_builtin: Token,
    undefined_identifier: Token,
    too_many_args: struct {
        pos: usize,
        parameters: []const Type,
    },
    builtin_arg_count: struct { builtin_extent: Extent, arg_count: usize },
    builtin_arg_type: struct {
        builtin_extent: Extent,
        arg_index: u32,
        expected: Type,
        actual: Type,
    },
    needed_type: struct {
        pos: usize,
        context: TypeContext,
        value: enum {
            @"no value",
            @"a string",
            @"an assembly",
        },
    },
    // an identifier was assigned a void value
    void_assignment: struct {
        id_extent: Extent,
    },
    void_argument: struct {
        arg_index: u32,
        first_arg_token: Token,
    },
    assembly_not_found: Extent,
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

    pub fn returnTypeFromValue(err: *Error, pos: usize, value: *const ?Value) error{Vm}!?Type {
        if (value.* == null) return err.set(.{ .needed_type = .{
            .pos = pos,
            .context = .@"return",
            .value = .@"no value",
        } });
        return err.typeFromValue(pos, .@"return", &value.*.?);
    }
    pub fn typeFromValue(err: *Error, pos: usize, context: TypeContext, value: *const Value) error{Vm}!?Type {
        return switch (value.*) {
            .type => |t| t,
            .string_literal => err.set(.{ .needed_type = .{
                .pos = pos,
                .context = context,
                .value = .@"a string",
            } }),
            .assembly => err.set(.{ .needed_type = .{
                .pos = pos,
                .context = context,
                .value = .@"an assembly",
            } }),
        };
    }
};

fn getLineNum(text: []const u8, offset: usize) u32 {
    var line_num: u32 = 1;
    for (text[0..@min(text.len, offset)]) |c| {
        if (c == '\n') line_num += 1;
    }
    return line_num;
}

pub fn deinit(vm: *Vm) void {
    vm.mem.deinit();
    vm.* = undefined;
}

fn stackEnsureUnusedSlot(vm: *Vm, allocator: std.mem.Allocator, out_err: *Error) error{Vm}!void {
    vm.stack.ensureUnusedCapacity(allocator, 1) catch return out_err.set(.oom);
}
fn stackPushAssume(vm: *Vm, value: Value) void {
    vm.stack.appendAssumeCapacity(value);
}

pub fn interpret(vm: *Vm) error{Vm}!void {
    var offset: usize = 0;
    while (true) {
        const first_token = lex(vm.text, offset);
        offset = first_token.end;
        switch (first_token.tag) {
            .eof => break,
            .builtin => {
                @panic("todo");
                // var maybe_value, offset = try vm.evalExpr(first_token.start);
                // if (maybe_value) |*value| value.deinit();
            },
            .identifier => {
                const second_token = lex(vm.text, offset);
                offset = second_token.end;
                switch (second_token.tag) {
                    .equal => {
                        const symbol: *Symbol = vm.mem.push(Symbol) catch return vm.err.set(.oom);
                        const value_addr = vm.mem.top();
                        offset = try vm.evalExpr(second_token.end);
                        if (value_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_assignment = .{
                            .id_extent = first_token.extent(),
                        } });
                        symbol.* = .{
                            .list_node = .{},
                            .extent = first_token.extent(),
                            .value_addr = value_addr,
                        };
                        vm.symbols.prepend(&symbol.list_node);
                    },
                    .l_paren => {
                        const name = vm.text[first_token.start..first_token.end];
                        const symbol = vm.lookup(name) orelse return vm.err.set(
                            .{ .undefined_identifier = first_token },
                        );
                        _ = symbol;
                        return vm.err.set(.{ .not_implemented = "function calls" });
                    },
                    else => return vm.err.set(.{ .unexpected_token = .{
                        .expected = "an '=' or '(' after identifier",
                        .token = second_token,
                    } }),
                }
            },
            .keyword_fn => {
                const id_extent = blk: {
                    const token = lex(vm.text, first_token.end);
                    switch (token.tag) {
                        .identifier => {},
                        else => return vm.err.set(.{ .unexpected_token = .{
                            .expected = "an identifier after 'fn' to name a function",
                            .token = token,
                        } }),
                    }
                    break :blk token.extent();
                };

                if (vm.lookup(vm.text[id_extent.start..id_extent.end])) |value| {
                    _ = value;
                    @panic("todo");
                }
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // std.log.err("TODO: check if id_extent conflicts"

                const after_open_paren = try eat(vm.text, &vm.err).token(id_extent.end, .l_paren);
                const function: *Function = vm.mem.push(Function) catch return vm.err.set(.oom);
                function.* = .{ .id_extent = id_extent };

                const return_type: *?Type = vm.mem.push(?Type) catch return vm.err.set(.oom);
                return_type.* = null;

                offset = after_open_paren;
                while (true) {
                    const next = lex(vm.text, offset);
                    switch (next.tag) {
                        .r_paren => {
                            offset = next.end;
                            break;
                        },
                        else => return vm.err.set(.{ .not_implemented = "fn with args" }),
                    }
                }

                // const symbol: *Symbol = vm.mem.push(Symbol) catch return vm.err.set(.oom);
                // const value_addr = vm.mem.top();
                // offset = try vm.evalExpr(second_token.end);
                // if (value_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_assignment = .{
                //     .id_extent = first_token.extent(),
                //     } });
                // symbol.* = .{
                //     .list_node = .{},
                //     .extent = first_token.extent(),
                //     .value_addr = value_addr,
                // };
                // vm.symbols.prepend(&symbol.list_node);

                // const entry = vm.symbol_table.getOrPut(
                // {}
                @panic("todo");

                // // const body_start = offset;
                // offset = try eat(vm.text, &vm.err).token(offset, .l_brace);
                // offset = try eat(vm.text, &vm.err).body(offset);
            },
            else => return vm.err.set(.{ .unexpected_token = .{
                .expected = "an EOF, identifier, builtin or 'fn' keyword",
                .token = first_token,
            } }),
        }
    }
}

fn lookup(vm: *Vm, needle: []const u8) ?*Symbol {
    // if (builtin_symbols.get(symbol)) |value| return value;
    var maybe_symbol = vm.symbols.first;
    while (maybe_symbol) |node| : (maybe_symbol = node.next) {
        const s: *Symbol = @fieldParentPtr("list_node", node);
        if (std.mem.eql(u8, needle, vm.text[s.extent.start..s.extent.end])) return s;
    }
    return null;
}

fn evalExpr(vm: *Vm, start: usize) error{Vm}!usize {
    const first_token = lex(vm.text, start);
    switch (first_token.tag) {
        .builtin => {
            const id = vm.text[first_token.start..first_token.end];
            const builtin = builtins.get(id) orelse return vm.err.set(.{ .unknown_builtin = first_token });
            const next = try eat(vm.text, &vm.err).token(first_token.end, .l_paren);
            const args_addr = vm.mem.top();
            const args_end = try vm.evalArgs(builtin.parameters(), next);
            try vm.evalBuiltin(first_token.extent(), builtin, args_addr);
            return args_end;
        },
        .identifier => {
            const id = vm.text[first_token.start..first_token.end];
            const second_token = lex(vm.text, first_token.end);
            switch (second_token.tag) {
                .l_paren => {
                    std.debug.panic("todo: lookup function '{s}'", .{id});
                    // return vm.err.set(.{ .not_implemented = "todo: ll" });
                },
                else => {
                    return vm.err.set(.{ .not_implemented = "identifier expressions" });
                },
            }
        },
        .string_literal => {
            @panic("todo");
            // return .{ .{ .string_literal = .{
            //     .start = first_token.start,
            //     .end = first_token.end,
            //     } }, first_token.end },
        },
        else => return vm.err.set(.{ .unexpected_token = .{
            .expected = "an expression",
            .token = first_token,
        } }),
    }
}

fn evalArgs(vm: *Vm, parameters: []const Type, start: usize) error{Vm}!usize {
    var arg_index: u32 = 0;
    var offset = start;
    while (true) : (arg_index += 1) {
        const first_token = lex(vm.text, offset);
        const after_expr = blk: switch (first_token.tag) {
            .r_paren => return first_token.end,
            else => {
                if (arg_index >= parameters.len) return vm.err.set(.{ .too_many_args = .{
                    .pos = first_token.start,
                    .parameters = parameters,
                } });

                if (true) @panic("todo");
                break :blk 0;
                // try vm.stackEnsureUnusedSlot(vm.allocator, &vm.err);
                // const maybe_value, const end = try vm.evalExpr(offset);
                // vm.stackPushAssume(maybe_value orelse return vm.err.set(.{ .void_argument = .{
                //     .arg_index = arg_index,
                //     .first_arg_token = first_token,
                // } }));
                // break :blk end;
            },
        };

        {
            const token = lex(vm.text, after_expr);
            switch (token.tag) {
                .r_paren => return token.end,
                .comma => {},
                else => return vm.err.set(.{ .unexpected_token = .{
                    .expected = "a ',' or close paren ')'",
                    .token = token,
                } }),
            }
            offset = token.end;
        }
    }
}

fn evalBuiltin(
    vm: *Vm,
    builtin_extent: Extent,
    builtin: Builtin,
    args_addr: Memory.Addr,
) error{Vm}!void {
    _ = vm;
    _ = builtin_extent;
    _ = args_addr;
    // const arg_count = vm.stack.items.len - stack_before;
    // if (arg_count != builtin.argCount()) return vm.err.set(.{
    //     .builtin_arg_count = .{ .builtin_extent = builtin_extent, .arg_count = arg_count },
    // });
    switch (builtin) {
        // .@"@Nothing" => return null,
        .@"@Nothing" => {},
        .@"@LogAssemblies" => {
            @panic("todo");
            // var context: LogAssemblies = .{ .vm = vm, .index = 0 };
            // std.log.info("mono_assembly_foreach:", .{});
            // vm.mono_funcs.assembly_foreach(&logAssemblies, &context);
            // std.log.info("mono_assembly_foreach done", .{});
            // return null;
        },
        .@"@LoadAssembly" => {
            @panic("todo");
            // const arg = vm.stack.items[vm.stack.items.len - 1];
            // const extent = switch (arg) {
            //     .string_literal => |e| e,
            //     else => return vm.err.set(.{
            //         .builtin_arg_type = .{
            //             .builtin_extent = builtin_extent,
            //             .arg_index = 0,
            //             .expected = .string_literal,
            //             .actual = arg.getType(),
            //         },
            //     }),
            // };
            // const slice = vm.text[extent.start + 1 .. extent.end - 1];
            // var context: FindAssembly = .{
            //     .vm = vm,
            //     .index = 0,
            //     .needle = slice,
            //     .match = null,
            // };
            // vm.mono_funcs.assembly_foreach(&findAssembly, &context);
            // if (context.match) |match| return .{ .assembly = match };
            // return vm.err.set(.{ .assembly_not_found = extent });
            // // if (slice.len > max_load_assembly_string) return vm.err.set(.{ .load_assembly_string_too_long = extent });
            // // var string_buf: [max_load_assembly_string + 1]u8 = undefined;
            // // @memcpy(string_buf[0..slice.len], slice);
            // // string_buf[slice.len] = 0;
            // // const cstr: [*:0]const u8 = string_buf[0..slice.len :0];

            // // std.log.info("loading assembly '{s}'...", .{std.mem.span(cstr)});

            // // return .{ .assembly = vm.mono_funcs.domain_assembly_open(vm.mono_domain, cstr) orelse {
            // //     std.log.info("mono_domain_assembly_open '{s}' failed", .{std.mem.span(cstr)});
            // //     return vm.err.set(.{ .load_assembly_failed = extent });
            // // } };
        },
    }
}

fn eat(text: []const u8, err: *Error) Eat {
    return .{ .text = text, .err = err };
}
const Eat = struct {
    text: []const u8,
    err: *Error,

    fn token(vm: Eat, start: usize, what: enum {
        l_paren,
        l_brace,
    }) error{Vm}!usize {
        const t = lex(vm.text, start);
        const expected_tag: Token.Tag = switch (what) {
            .l_paren => .l_paren,
            .l_brace => .l_brace,
        };
        if (t.tag != expected_tag) return vm.err.set(.{ .unexpected_token = .{
            .expected = switch (what) {
                .l_paren => "an open paren '('",
                .l_brace => "an open brace '{'",
            },
            .token = t,
        } });
        return t.end;
    }

    fn body(vm: Eat, start: usize) error{Vm}!usize {
        var offset: usize = start;
        while (true) {
            const first_token = lex(vm.text, offset);
            offset = first_token.end;
            switch (first_token.tag) {
                .r_brace => return first_token.end,
                .eof => return vm.err.set(.{ .unexpected_token = .{
                    .expected = "'}' to close function body",
                    .token = first_token,
                } }),
                .builtin => offset = try vm.expr(first_token.start),
                .identifier => {
                    // const id = text[first_token.start..first_token.end];
                    const second_token = lex(vm.text, offset);
                    offset = second_token.end;
                    switch (second_token.tag) {
                        .equal => offset = try vm.expr(second_token.end),
                        .l_paren => return vm.err.set(.{ .not_implemented = "eat function call" }),
                        else => return vm.err.set(.{ .unexpected_token = .{
                            .expected = "an '=' or '(' after identifier",
                            .token = second_token,
                        } }),
                    }
                },
                // .keyword_fn => {
                //     const return_type: ?Type, const after_return_type = blk: {
                //         const next_token = lex(vm.text, first_token.end);
                //         if (next_token.isVoid(vm.text)) break :blk .{ null, next_token.end };
                //         const return_type_value, const after_return_type = try vm.evalExpr(first_token.end);
                //         // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                //         // defer TODO: clean up return_type_value
                //         const return_type = try vm.err.typeFromValue(
                //             first_token.end,
                //             .@"return",
                //             &return_type_value,
                //         );
                //         break :blk .{ return_type, after_return_type };
                //     };
                //     _ = return_type;

                //     const name_token = lex(vm.text, after_return_type);
                //     switch (name_token.tag) {
                //         .identifier => {},
                //         else => return vm.err.set(.{ .unexpected_token = .{
                //             .expected = "a function name identifier",
                //             .token = name_token,
                //         } }),
                //     }
                //     const after_open_paren = try eatToken(&vm.err, vm.text, name_token.end, .l_paren);
                //     offset = after_open_paren;
                //     while (true) {
                //         const next = lex(vm.text, offset);
                //         switch (next.tag) {
                //             .r_paren => {
                //                 offset = next.end;
                //                 break;
                //             },
                //             else => return vm.err.set(.{ .not_implemented = "fn with args" }),
                //         }
                //     }
                //     offset = try eatToken(&vm.err, vm.text, offset, .l_brace);
                //     offset = try eatBody(&vm.err, vm.text, offset);
                // },
                else => return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an EOF, identifier, builtin or 'fn' keyword",
                    .token = first_token,
                } }),
            }
        }
    }

    fn expr(vm: Eat, start: usize) error{Vm}!usize {
        const first_token = lex(vm.text, start);
        switch (first_token.tag) {
            .builtin => {
                return vm.err.set(.{ .not_implemented = "eat builtin" });
                // const id = vm.text[first_token.start..first_token.end];
                // const builtin = builtins.get(id) orelse return vm.err.set(.{ .unknown_builtin = first_token });
                // const next = try eatToken(&vm.err, vm.text, first_token.end, .l_paren);
                // const stack_before = vm.stack.items.len;
                // const arg_end = try vm.evalArgs(next);
                // return .{ try vm.evalBuiltin(first_token.extent(), builtin, stack_before), arg_end };
            },
            .identifier => {
                return vm.err.set(.{ .not_implemented = "eat identifier" });
                // const id = vm.text[first_token.start..first_token.end];
                // const second_token = lex(vm.text, first_token.end);
                // switch (second_token.tag) {
                //     .l_paren => {
                //         std.debug.panic("todo: lookup function '{s}'", .{id});
                //     },
                //     else => {
                //         return vm.err.set(.{ .not_implemented = "identifier expressions" });
                //     },
                // }
            },
            .string_literal => return first_token.end,
            else => return vm.err.set(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } }),
        }
    }
};

const FindAssembly = struct {
    vm: *Vm,
    index: usize,
    needle: []const u8,
    match: ?*mono.Assembly,
};
fn findAssembly(assembly_opaque: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const assembly: *mono.Assembly = @ptrCast(assembly_opaque);
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
    const assembly: *mono.Assembly = @ptrCast(assembly_opaque);
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

const Builtin = enum {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // temporary builtin, remove this later
    @"@Nothing",
    @"@LogAssemblies",
    @"@LoadAssembly",

    pub fn parameters(builtin: Builtin) []const Type {
        return switch (builtin) {
            .@"@Nothing" => &.{},
            .@"@LogAssemblies" => &.{},
            .@"@LoadAssembly" => &.{.string_literal},
        };
    }
    pub fn argCount(builtin: Builtin) u8 {
        return switch (builtin) {
            .@"@Nothing" => 0,
            .@"@LogAssemblies" => 0,
            .@"@LoadAssembly" => 1,
        };
    }
};
pub const builtins = std.StaticStringMap(Builtin).initComptime(.{
    .{ "@Nothing", .@"@Nothing" },
    .{ "@LogAssemblies", .@"@LogAssemblies" },
    .{ "@LoadAssembly", .@"@LoadAssembly" },
});
// pub const builtin_symbols = std.StaticStringMap(Value).initComptime(.{
//     // .{ "void", .{ .type =  },
//     // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//     // TODO: remove this
//     .{ "placeholder", Value{ .type = null } },
// });

const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub fn extent(t: Token) Extent {
        return .{ .start = t.start, .end = t.end };
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
        // bang,
        // pipe,
        // pipe_pipe,
        // pipe_equal,
        equal,
        // equal_equal,
        // equal_angle_bracket_right,
        // bang_equal,
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
        // plus,
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
        // angle_bracket_left,
        // angle_bracket_left_equal,
        // angle_bracket_angle_bracket_left,
        // angle_bracket_angle_bracket_left_equal,
        // angle_bracket_angle_bracket_left_pipe,
        // angle_bracket_angle_bracket_left_pipe_equal,
        // angle_bracket_right,
        // angle_bracket_right_equal,
        // angle_bracket_angle_bracket_right,
        // angle_bracket_angle_bracket_right_equal,
        // tilde,
        // number_literal,
        // doc_comment,
        // container_doc_comment,
        keyword_fn,
    };
    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        // .{ "and", .keyword_and },
        // .{ "break", .keyword_break },
        // .{ "catch", .keyword_catch },
        // .{ "const", .keyword_const },
        // .{ "continue", .keyword_continue },
        // .{ "defer", .keyword_defer },
        // .{ "else", .keyword_else },
        // .{ "enum", .keyword_enum },
        // .{ "errdefer", .keyword_errdefer },
        // .{ "error", .keyword_error },
        // .{ "export", .keyword_export },
        // .{ "extern", .keyword_extern },
        .{ "fn", .keyword_fn },
        // .{ "for", .keyword_for },
        // .{ "if", .keyword_if },
        // .{ "inline", .keyword_inline },
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
        // .{ "var", .keyword_var },
        // .{ "volatile", .keyword_volatile },
        // .{ "while", .keyword_while },
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
            .equal => try writer.writeAll("an equal '=' character"),
            .l_paren => try writer.writeAll("an open paren '('"),
            .r_paren => try writer.writeAll("a close paren ')'"),
            .l_brace => try writer.writeAll("an open brace '{'"),
            .r_brace => try writer.writeAll("a close brace '}'"),
            .l_bracket => try writer.writeAll("an open bracket '['"),
            .r_bracket => try writer.writeAll("a close bracket ']'"),
            .period => try writer.writeAll("a period '.'"),
            .slash => try writer.writeAll("a slash '/'"),
            .comma => try writer.writeAll("a comma ','"),
            .keyword_fn => try writer.writeAll("the 'fn' keyword"),
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
        slash: usize,
        line_comment,
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
            .slash => |start| .{ .tag = .slash, .start = start, .end = index },
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
                    '=' => return .{ .tag = .equal, .start = index, .end = index + 1 },
                    // '!' => continue :state .bang,
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
                    // '+' => continue :state .plus,
                    // '<' => continue :state .angle_bracket_left,
                    // '>' => continue :state .angle_bracket_right,
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
                    // '0'...'9' => {
                    //     result.tag = .number_literal;
                    //     self.index += 1;
                    //     continue :state .int;
                    // },
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
            \\cs = @LoadAssembly("Assembly-CSharp")
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
        try it.expect(.equal, "=");
        try it.expect(.builtin, "@LoadAssembly");
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
        try it.expect(.equal, "=");
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

const ErrorFmt = struct {
    err: *const Error,
    text: []const u8,
    pub fn format(f: *const ErrorFmt, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (f.err.*) {
            .not_implemented => |n| try writer.print("{s} not implemented", .{n}),
            .unexpected_token => |e| try writer.print(
                "{d}: syntax error: expected {s} but got {f}",
                .{
                    getLineNum(f.text, e.token.start),
                    e.expected,
                    e.token.fmt(f.text),
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
            .too_many_args => |e| switch (e.parameters.len) {
                0 => try writer.print("{d}: function has no parameters", .{
                    getLineNum(f.text, e.pos),
                }),
                1 => try writer.print("{d}: function only accepts 1 parameter", .{
                    getLineNum(f.text, e.pos),
                }),
                else => try writer.print("{d}: function only accepts {} parameters", .{
                    getLineNum(f.text, e.pos),
                    e.parameters.len,
                }),
            },
            .builtin_arg_count => |b| {
                const builtin_str = f.text[b.builtin_extent.start..b.builtin_extent.end];
                const builtin = builtins.get(builtin_str).?;
                const arg_count = builtin.argCount();
                const arg_suffix: []const u8 = if (arg_count == 1) "" else "s";
                try writer.print(
                    "{d}: builtin '{s}' requires {} arg{s} but got {}",
                    .{
                        getLineNum(f.text, b.builtin_extent.start),
                        builtin_str,
                        arg_count,
                        arg_suffix,
                        b.arg_count,
                    },
                );
            },
            .builtin_arg_type => |b| {
                const builtin_str = f.text[b.builtin_extent.start..b.builtin_extent.end];
                try writer.print(
                    "{d}: builtin '{s}' argument {} type mismatch,  expected '{s}' but got '{s}'",
                    .{
                        getLineNum(f.text, b.builtin_extent.start),
                        builtin_str,
                        b.arg_index + 1,
                        @tagName(b.expected),
                        @tagName(b.actual),
                    },
                );
            },
            .needed_type => |n| try writer.print(
                "{d}: expected a {s} type but got {s}",
                .{
                    getLineNum(f.text, lex(f.text, n.pos).start),
                    @tagName(n.context),
                    @tagName(n.value),
                },
            ),
            .void_assignment => |v| try writer.print(
                "{d}: nothing was assigned to identifier '{s}'",
                .{
                    getLineNum(f.text, v.id_extent.start),
                    f.text[v.id_extent.start..v.id_extent.end],
                },
            ),
            .void_argument => |v| try writer.print(
                "{d}: nothing was assigned function argument {}",
                .{
                    getLineNum(f.text, v.first_arg_token.start),
                    v.arg_index + 1,
                },
            ),
            // .load_assembly_string_too_long => |token| try writer.print(
            //     "{d}: @LoadAssembly string too long ({} bytes but max is {}) {s}",
            //     .{
            //         getLineNum(f.text, token.start),
            //         token.end - token.start - 2,
            //         max_load_assembly_string,
            //         f.text[token.start..token.end],
            //     },
            // ),
            .assembly_not_found => |extent| try writer.print(
                "{d}: @LoadAssembly failed, assembly '{s}' not found",
                .{
                    getLineNum(f.text, extent.start),
                    f.text[extent.start..extent.end],
                },
            ),
            .oom => try writer.writeAll("out of memory"),
        }
    }
};

fn testBadCode(text: []const u8, expected_error: []const u8) !void {
    // std.debug.print("testing bad code:\n---\n{s}\n---\n", .{text});
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var vm: Vm = .{
        .mono_funcs = undefined,
        .mono_domain = undefined,
        // .allocator = gpa.allocator(),
        .err = undefined,
        .text = text,
        .mem = .{ .allocator = gpa.allocator() },
        .symbols = .{},
    };
    defer vm.deinit();
    if (vm.interpret()) {
        return error.TestUnexpectedSuccess;
    } else |_| {
        var buf: [1000]u8 = undefined;
        const actual_error = try std.fmt.bufPrint(&buf, "{f}", .{vm.err.fmt(text)});
        if (!std.mem.eql(u8, expected_error, actual_error)) {
            std.log.err("actual error string\n\"{f}\"\n", .{std.zig.fmtString(actual_error)});
            return error.TestUnexpectedError;
        }
    }
}

test "bad code" {
    try testBadCode("example_id = @Nothing()", "1: nothing was assigned to identifier 'example_id'");
    try testBadCode("fn", "1: syntax error: expected an identifier after 'fn' to name a function but got EOF");
    try testBadCode("fn a", "1: syntax error: expected an open paren '(' but got EOF");
    try testBadCode("fn @Nothing()", "1: syntax error: expected an identifier after 'fn' to name a function but got the builtin function '@Nothing'");
    try testBadCode("fn foo", "1: syntax error: expected an open paren '(' but got EOF");
    try testBadCode("fn foo \"hello\"", "1: syntax error: expected an open paren '(' but got a string literal \"hello\"");
    try testBadCode("fn foo )", "1: syntax error: expected an open paren '(' but got a close paren ')'");
    try testBadCode("foo()", "1: undefined identifier 'foo'");
    try testBadCode("fn foo(){}", "");
    // try testBadCode("fn void foo(){} fn void foo(){}", "");
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
}

const std = @import("std");
const mono = @import("mono.zig");
const Memory = @import("Memory.zig");
