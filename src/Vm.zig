const Vm = @This();

mono_funcs: *const mono.Funcs,
mono_domain: *const mono.Domain,
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

const FunctionSignature = struct {
    return_type: ?Type,
    body: union(enum) {
        managed: *const mono.Method,
        text_source: usize,
    },
    param_count: u16,
};

const Type = enum {
    integer,
    string_literal,
    function,
    assembly,
    class,
    pub fn what(t: Type) []const u8 {
        return switch (t) {
            .integer => "an integer",
            .string_literal => "a string literal",
            .function => "a function",
            .assembly => "an assembly",
            .class => "a class",
        };
    }
};

const TypeContext = enum { @"return", param };

pub const Error = union(enum) {
    not_implemented: [:0]const u8,
    unexpected_token: struct { expected: [:0]const u8, token: Token },
    unknown_builtin: Token,
    undefined_identifier: Token,
    num_literal_overflow: Extent,
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
        actual: u16,
    },
    arg_type: struct {
        arg_pos: usize,
        arg_index: u16,
        expected: Type,
        actual: Type,
    },
    too_many_args: struct {
        pos: usize,
        param_count: u16,
    },
    import_from_non_class: struct {
        pos: usize,
        actual_type: ?Type,
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
    id_too_big: Extent,
    missing_class: struct {
        assembly: *mono.Assembly,
        namespace: Extent,
        name: Extent,
    },
    missing_method: struct {
        class: *mono.Class,
        name: Extent,
        param_count: i64,
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

const ManagedId = struct {
    buf: [max + 1]u8,
    len: std.math.IntFittingRange(0, max),

    // C# limits identifiers to 1023 characters (class names, method names, variables etc).
    const max = 1023;

    pub fn slice(self: *const ManagedId) [:0]const u8 {
        return self.buf[0..self.len :0];
    }
};

pub fn evalRoot(vm: *Vm) error{Vm}!void {
    var offset: usize = 0;
    while (offset < vm.text.len) {
        const after_statement = switch (try vm.evalStatement(offset)) {
            .not_statement => |token| {
                if (token.tag == .eof) return;
                return vm.err.set(.{ .unexpected_token = .{
                    .expected = "a statement",
                    .token = token,
                } });
            },
            .statement_end => |end| end,
        };
        std.debug.assert(after_statement > offset);
        offset = after_statement;
    }
}

pub fn evalBlock(vm: *Vm, start: usize) error{Vm}!usize {
    var offset: usize = start;
    while (true) {
        const after_statement = switch (try vm.evalStatement(offset)) {
            .not_statement => |token| {
                if (token.tag == .r_brace) return token.end;
                return vm.err.set(.{ .unexpected_token = .{
                    .expected = "a statement",
                    .token = token,
                } });
            },
            .statement_end => |end| end,
        };
        std.debug.assert(after_statement > offset);
        offset = after_statement;
    }
}
fn evalStatement(vm: *Vm, start: usize) error{Vm}!union(enum) {
    not_statement: Token,
    statement_end: usize,
} {
    const first_token = lex(vm.text, start);
    switch (first_token.tag) {
        .identifier => {
            const second_token = lex(vm.text, first_token.end);
            if (second_token.tag == .equal) {
                const symbol: *Symbol = try vm.push(Symbol);
                symbol.* = undefined;
                const value_addr = vm.mem.top();
                const expr_first_token = lex(vm.text, second_token.end);
                const after_expr = try vm.evalExpr(expr_first_token) orelse return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an expresson",
                    .token = expr_first_token,
                } });
                if (value_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_assignment = .{
                    .id_extent = first_token.extent(),
                } });
                symbol.* = .{
                    .list_node = .{},
                    .extent = first_token.extent(),
                    .value_addr = value_addr,
                };
                vm.symbols.prepend(&symbol.list_node);
                return .{ .statement_end = after_expr };
            }
        },
        .keyword_fn => {
            const id_extent = blk: {
                const token = lex(vm.text, first_token.end);
                if (token.tag != .identifier) return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an identifier after 'fn'",
                    .token = token,
                } });
                break :blk token.extent();
            };

            // TODO: should we not allow shadowing?
            // if (vm.lookup(
            //     vm.text[id_extent.start..id_extent.end],
            // )) |value| return vm.err.set(...);

            const after_open_paren = try eat(vm.text, &vm.err).eatToken(id_extent.end, .l_paren);
            const signature_addr = vm.mem.top();
            // // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // std.debug.print(
            //     "Function '{s}' DefinitionAddr={f}\n",
            //     .{ vm.text[id_extent.start..id_extent.end], value_addr },
            // );
            const signature: *FunctionSignature = try vm.push(FunctionSignature);
            signature.* = .{
                .return_type = null,
                .body = .{ .text_source = undefined },
                .param_count = 0,
            };

            var offset = after_open_paren;
            while (true) {
                const next = lex(vm.text, offset);
                switch (next.tag) {
                    .r_paren => {
                        offset = next.end;
                        break;
                    },
                    else => return vm.err.set(.{ .not_implemented = "fn with args" }),
                }

                @panic("todo: increment param_count.*");
                // signature.param_count += 1;
            }

            // TODO: parse and set the return type if we want to support that
            offset = try eat(vm.text, &vm.err).eatToken(offset, .l_brace);
            signature.body.text_source = offset;

            const function_value_addr = vm.mem.top();
            (try vm.push(Type)).* = .function;
            (try vm.push(Memory.Addr)).* = signature_addr;

            const function_symbol: *Symbol = try vm.push(Symbol);
            function_symbol.* = .{
                .list_node = .{},
                .extent = id_extent,
                .value_addr = function_value_addr,
            };
            vm.symbols.prepend(&function_symbol.list_node);
            return .{ .statement_end = try eat(vm.text, &vm.err).evalBlock(offset) };
        },
        .keyword_import => {
            const id_extent = blk: {
                const token = lex(vm.text, first_token.end);
                if (token.tag != .identifier) return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an identifier after 'import'",
                    .token = token,
                } });
                break :blk token.extent();
            };

            const param_count: u16, const param_end = blk: {
                const token = lex(vm.text, id_extent.end);
                if (token.tag != .number_literal) return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an parameter count integer",
                    .token = token,
                } });
                const param_str = vm.text[token.start..token.end];
                const value = std.fmt.parseInt(u16, param_str, 0) catch |err| switch (err) {
                    error.Overflow => return vm.err.set(.{ .num_literal_overflow = token.extent() }),
                    error.InvalidCharacter => unreachable,
                };
                break :blk .{ value, token.end };
            };
            const after_from = try eat(vm.text, &vm.err).eatToken(param_end, .identifier_from);

            const expr_addr = vm.mem.top();

            const first_class_token = lex(vm.text, after_from);
            const after_expr = try vm.evalExpr(first_class_token) orelse return vm.err.set(.{ .unexpected_token = .{
                .expected = "an expression after 'from'",
                .token = first_class_token,
            } });

            if (expr_addr.eql(vm.mem.top())) return vm.err.set(.{ .import_from_non_class = .{
                .pos = first_class_token.start,
                .actual_type = null,
            } });

            const from_type, const from_value_addr = vm.readValue(Type, expr_addr);
            if (from_type != .class) return vm.err.set(.{ .import_from_non_class = .{
                .pos = first_class_token.start,
                .actual_type = from_type,
            } });
            const class, const end_addr = vm.readValue(*mono.Class, from_value_addr);
            std.debug.assert(end_addr.eql(vm.mem.top()));
            _ = vm.mem.discardFrom(expr_addr);

            const name = try vm.managedId(id_extent);
            const method = vm.mono_funcs.class_get_method_from_name(class, name.slice(), param_count) orelse return vm.err.set(
                .{ .missing_method = .{
                    .class = class,
                    .name = id_extent,
                    .param_count = param_count,
                } },
            );

            const method_flags = vm.mono_funcs.method_get_flags(method, null);
            std.debug.print("MethodFlags {}", .{method_flags});

            const method_sig = vm.mono_funcs.method_signature(method) orelse @panic(
                "method has no signature?",
            );

            const return_type: ?Type = blk: {
                const return_type = vm.mono_funcs.signature_get_return_type(method_sig) orelse @panic(
                    "method has no return type?",
                );
                const return_type_kind = vm.mono_funcs.type_get_type(return_type);
                break :blk switch (return_type_kind) {
                    .void => null,
                    else => |k| std.debug.panic(
                        "todo: handle return type '{?s}' ({})",
                        .{ std.enums.tagName(mono.TypeKind, k), @intFromEnum(k) },
                    ),
                };
            };

            if (method_flags.static) {
                return vm.err.set(.{ .not_implemented = "calling non-static methods" });
            }

            var iterator: ?*anyopaque = null;
            for (0..@intCast(param_count)) |param_index| {
                const param_type = vm.mono_funcs.signature_get_params(
                    method_sig,
                    &iterator,
                ) orelse std.debug.panic(
                    "mono_signature_get_params with index {} returned null even though there are {} parameters",
                    .{ param_index, param_count },
                );
                _ = param_type;
                return vm.err.set(.{ .not_implemented = "methods with params" });
            }

            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: we also need to know if this method is static or not, if not,
            //       then we need to add the "this" pointer parameter
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

            const signature_addr = vm.mem.top();
            const signature: *FunctionSignature = try vm.push(FunctionSignature);
            signature.* = .{
                .return_type = return_type,
                .body = .{ .managed = method },
                .param_count = param_count,
            };

            for (0..param_count) |param_index| {
                _ = param_index;
                return vm.err.set(.{ .not_implemented = "managed functions with parameters" });
            }

            const function_value_addr = vm.mem.top();
            (try vm.push(Type)).* = .function;
            (try vm.push(Memory.Addr)).* = signature_addr;

            const function_symbol: *Symbol = try vm.push(Symbol);
            function_symbol.* = .{
                .list_node = .{},
                .extent = id_extent,
                .value_addr = function_value_addr,
            };
            vm.symbols.prepend(&function_symbol.list_node);
            return .{ .statement_end = after_expr };
        },
        else => {},
    }

    const expr_end = try vm.evalExpr(first_token) orelse return .{ .not_statement = first_token };
    const next_token = lex(vm.text, expr_end);
    if (next_token.tag != .equal) return .{ .statement_end = expr_end };

    @panic("todo");
}
fn evalExpr(vm: *Vm, first_token: Token) error{Vm}!?usize {
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
            return vm.err.set(.{ .not_implemented = "array index" });
        },
        .period => {
            const id_extent = blk: {
                const id_token = lex(vm.text, suffix_op_token.end);
                if (id_token.tag != .identifier) return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an identifier after '.'",
                    .token = id_token,
                } });
                break :blk id_token.extent();
            };
            if (expr_addr.eql(vm.mem.top())) return vm.err.set(
                .{ .void_field = .{ .start = suffix_op_token.start } },
            );
            const expr_type, const value_addr = vm.readValue(Type, expr_addr);
            _ = value_addr;
            return switch (expr_type) {
                .integer, .string_literal, .function, .assembly, .class => vm.err.set(.{ .no_field = .{
                    .start = suffix_op_token.start,
                    .field = id_extent,
                    .unexpected_type = expr_type,
                } }),
                // .class => {
                //     const class, const end = vm.readValue(*mono.Class, value_addr);
                //     std.debug.assert(end.eql(vm.mem.top()));
                //     _ = vm.mem.discardFrom(expr_addr);
                //     (try vm.push(Type)).* = .class_member;
                //     (try vm.push(*mono.Class)).* = class;
                //     // (try vm.push(u8)).* = 0;
                //     (try vm.push(usize)).* = id_extent.start;
                //     return id_extent.end;
                // },
                // .class_member => {
                //     return vm.err.set(.{ .not_implemented = "class members(2)" });
                // },
                // .assembly_field => {
                //     _, const id_count_addr = vm.readValue(*mono.Assembly, value_addr);
                //     const id_count_ptr, var next_addr = vm.readPointer(u8, id_count_addr);
                //     if (id_count_ptr.* == 255) return vm.err.set(
                //         .{ .too_many_assembly_fields = .{ .pos = id_extent.start } },
                //     );
                //     for (0..id_count_ptr.* + 1) |_| {
                //         _, next_addr = vm.readValue(usize, next_addr);
                //     }
                //     std.debug.assert(next_addr.eql(vm.mem.top()));
                //     (try vm.push(usize)).* = id_extent.start;
                //     id_count_ptr.* += 1;
                //     return id_extent.end;
                // },
            };
        },
        .l_paren => {
            if (expr_addr.eql(vm.mem.top())) return vm.err.set(.{ .called_non_function = .{
                .start = expr_first_token.start,
                .unexpected_type = null,
            } });
            const expr_type, const expr_value_addr = vm.readValue(Type, expr_addr);
            if (expr_type == .function) {
                const signature_addr, const end_addr = vm.readValue(Memory.Addr, expr_value_addr);
                std.debug.assert(end_addr.eql(vm.mem.top()));
                _ = vm.mem.discardFrom(expr_addr);
                const signature: *FunctionSignature, const params_addr = vm.readPointer(FunctionSignature, signature_addr);

                // std.debug.print("Sig {}", .{signature.*});
                const mem_before_args = vm.mem.top();

                var offset = suffix_op_token.end;
                if (signature.param_count == 0) {
                    const t = lex(vm.text, offset);
                    if (t.tag != .r_paren) return vm.err.set(.{ .too_many_args = .{
                        .pos = t.start,
                        .param_count = signature.param_count,
                    } });
                    offset = t.end;
                } else {
                    _ = params_addr;
                    return vm.err.set(.{ .not_implemented = "calling functions with parameters" });
                }

                switch (signature.body) {
                    .text_source => |start| {
                        _ = try vm.evalBlock(start);
                    },
                    .managed => |method| {
                        const method_flags = vm.mono_funcs.method_get_flags(method, null);
                        // std.debug.print("MethodFlags {}", .{method_flags});
                        if (!method_flags.static) return vm.err.set(.{ .not_implemented = "calling non-static methods" });
                        if (signature.param_count != 0) return vm.err.set(.{ .not_implemented = "calling managed functions with parameters" });
                        if (signature.return_type != null) return vm.err.set(.{ .not_implemented = "calling managed function with return types" });
                        // var exception: *const mono.Object = undefined;
                        // const result = vm.mono_funcs.runtime_invoke(method, null, null, &exception);
                        const maybe_result = vm.mono_funcs.runtime_invoke(method, null, null, null);
                        if (maybe_result) |result| {
                            _ = result;
                            return vm.err.set(.{ .not_implemented = "finish calling managed method" });
                        }
                    },
                }

                if (signature.return_type) |return_type| {
                    _ = return_type;
                    return vm.err.set(.{ .not_implemented = "function calls with return types" });
                } else {
                    std.debug.assert(mem_before_args.eql(vm.mem.top()));
                }
                return offset;
            } else return vm.err.set(.{ .called_non_function = .{
                .start = expr_first_token.start,
                .unexpected_type = expr_type,
            } });
        },
        else => null,
    };
}

fn pushValueFromAddr(vm: *Vm, src_addr: Memory.Addr) error{Vm}!void {
    const value_type, const value_addr = vm.readValue(Type, src_addr);
    (try vm.push(Type)).* = value_type;
    switch (value_type) {
        .integer => {
            const value_ptr = vm.mem.toPointer(i64, value_addr);
            (try vm.push(i64)).* = value_ptr.*;
        },
        .string_literal => {
            const token_start_ptr = vm.mem.toPointer(usize, value_addr);
            (try vm.push(usize)).* = token_start_ptr.*;
        },
        .function => {
            const signature_addr_ptr = vm.mem.toPointer(Memory.Addr, value_addr);
            (try vm.push(Memory.Addr)).* = signature_addr_ptr.*;
        },
        .assembly => {
            const assembly_ptr = vm.mem.toPointer(*mono.Assembly, value_addr);
            (try vm.push(*mono.Assembly)).* = assembly_ptr.*;
        },
        .class => {
            const class_ptr = vm.mem.toPointer(*mono.Class, value_addr);
            (try vm.push(*mono.Class)).* = class_ptr.*;
        },
    }
}

fn evalPrimaryTypeExpr(vm: *Vm, first_token: Token) error{Vm}!?usize {
    return switch (first_token.tag) {
        .identifier => {
            const string = vm.text[first_token.start..first_token.end];
            const symbol = vm.lookup(string) orelse return vm.err.set(
                .{ .undefined_identifier = first_token },
            );
            try vm.pushValueFromAddr(symbol.value_addr);
            return first_token.end;
        },
        .string_literal => {
            (try vm.push(Type)).* = .string_literal;
            (try vm.push(usize)).* = first_token.start;
            return first_token.end;
        },
        .builtin => {
            const id = vm.text[first_token.start..first_token.end];
            const builtin = builtins.get(id) orelse return vm.err.set(.{ .unknown_builtin = first_token });
            const next = try eat(vm.text, &vm.err).eatToken(first_token.end, .l_paren);
            const args_addr = vm.mem.top();
            const args_end = try vm.evalArgs(builtin.paramCount(), .{ .builtin = builtin.params() }, next);
            try vm.evalBuiltin(first_token.extent(), builtin, args_addr);
            return args_end;
        },
        .number_literal => {
            const str = vm.text[first_token.start..first_token.end];
            const value = std.fmt.parseInt(i64, str, 10) catch |err| switch (err) {
                error.Overflow => return vm.err.set(.{ .num_literal_overflow = first_token.extent() }),
                error.InvalidCharacter => unreachable,
            };
            (try vm.push(Type)).* = .integer;
            (try vm.push(i64)).* = value;
            return first_token.end;
        },
        else => null,
    };
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

fn push(vm: *Vm, comptime T: type) error{Vm}!*T {
    return vm.mem.push(T) catch return vm.err.set(.oom);
}
fn readPointer(vm: *Vm, comptime T: type, addr: Memory.Addr) struct { *T, Memory.Addr } {
    return .{ vm.mem.toPointer(T, addr), vm.mem.after(T, addr) };
}
fn readValue(vm: *Vm, comptime T: type, addr: Memory.Addr) struct { T, Memory.Addr } {
    return .{ vm.mem.toPointer(T, addr).*, vm.mem.after(T, addr) };
}

fn evalArgs(
    vm: *Vm,
    param_count: u16,
    params: union(enum) {
        builtin: []const Type,
        addr: Memory.Addr,
    },
    start: usize,
) error{Vm}!usize {
    var arg_index: u16 = 0;
    var offset = start;
    while (true) {
        const first_token = lex(vm.text, offset);
        if (first_token.tag == .r_paren) {
            offset = first_token.end;
            break;
        }
        if (arg_index >= param_count) return vm.err.set(.{
            .too_many_args = .{
                .pos = first_token.start,
                .param_count = param_count,
                // .parameters = parameters,
            },
        });
        const arg_addr = vm.mem.top();
        offset = try vm.evalExpr(first_token) orelse return vm.err.set(.{ .unexpected_token = .{
            .expected = "an expression",
            .token = first_token,
        } });
        if (arg_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_argument = .{
            .arg_index = arg_index,
            .first_arg_token = first_token,
        } });

        const arg_type = vm.mem.toPointer(Type, arg_addr).*;
        switch (params) {
            .builtin => |p| if (p[arg_index] != arg_type) return vm.err.set(.{ .arg_type = .{
                .arg_pos = first_token.start,
                .arg_index = arg_index,
                .expected = p[arg_index],
                .actual = arg_type,
            } }),
            .addr => @panic("todo"),
        }

        arg_index += 1;
        {
            const token = lex(vm.text, offset);
            offset = token.end;
            switch (token.tag) {
                .r_paren => break,
                .comma => {},
                else => return vm.err.set(.{ .unexpected_token = .{
                    .expected = "a ',' or close paren ')'",
                    .token = token,
                } }),
            }
        }
    }
    if (arg_index != param_count) return vm.err.set(.{ .arg_count = .{
        .start = start,
        .expected = param_count,
        .actual = arg_index,
    } });
    return offset;
}

fn evalBuiltin(
    vm: *Vm,
    builtin_extent: Extent,
    builtin: Builtin,
    args_addr: Memory.Addr,
) error{Vm}!void {
    _ = builtin_extent;
    switch (builtin) {
        .@"@Nothing" => {},
        .@"@LogAssemblies" => {
            var context: LogAssemblies = .{ .vm = vm, .index = 0 };
            std.log.info("mono_assembly_foreach:", .{});
            vm.mono_funcs.assembly_foreach(&logAssemblies, &context);
            std.log.info("mono_assembly_foreach done", .{});
        },
        .@"@Assembly" => {
            const arg_type, const token_start_addr = vm.readValue(Type, args_addr);
            std.debug.assert(arg_type == .string_literal);
            const token_start, const end_addr = vm.readValue(usize, token_start_addr);
            std.debug.assert(vm.text[token_start] == '"');
            std.debug.assert(end_addr.eql(vm.mem.top()));
            _ = vm.mem.discardFrom(args_addr);
            const token = lex(vm.text, token_start);
            std.debug.assert(token.tag == .string_literal);
            std.debug.assert(vm.text[token.end - 1] == '"');
            const slice = vm.text[token_start + 1 .. token.end - 1];
            var context: FindAssembly = .{
                .vm = vm,
                .index = 0,
                .needle = slice,
                .match = null,
            };
            vm.mono_funcs.assembly_foreach(&findAssembly, &context);
            const match = context.match orelse return vm.err.set(
                .{ .assembly_not_found = token.extent() },
            );
            (try vm.push(Type)).* = .assembly;
            (try vm.push(*mono.Assembly)).* = match;
        },
        .@"@Class" => {
            const assembly_type, const assembly_addr = vm.readValue(Type, args_addr);
            std.debug.assert(assembly_type == .assembly);
            const assembly, const namespace_type_addr = vm.readValue(*mono.Assembly, assembly_addr);

            const namespace_type, const namespace_token_addr = vm.readValue(Type, namespace_type_addr);
            std.debug.assert(namespace_type == .string_literal);
            const namespace_token_start, const name_type_addr = vm.readValue(usize, namespace_token_addr);
            std.debug.assert(vm.text[namespace_token_start] == '"');

            const name_type, const name_token_addr = vm.readValue(Type, name_type_addr);
            std.debug.assert(name_type == .string_literal);
            const name_token_start, const end_addr = vm.readValue(usize, name_token_addr);
            std.debug.assert(vm.text[name_token_start] == '"');

            std.debug.assert(end_addr.eql(vm.mem.top()));
            _ = vm.mem.discardFrom(args_addr);

            const namespace_token = lex(vm.text, namespace_token_start);
            const name_token = lex(vm.text, name_token_start);
            std.debug.assert(namespace_token.tag == .string_literal);
            std.debug.assert(name_token.tag == .string_literal);
            std.debug.assert(vm.text[namespace_token.end - 1] == '"');
            std.debug.assert(vm.text[name_token.end - 1] == '"');

            const namespace = try vm.managedId(namespace_token.extentTrimmed());
            const name = try vm.managedId(name_token.extentTrimmed());

            const image = vm.mono_funcs.assembly_get_image(assembly) orelse @panic(
                "mono_assembly_get_image returned null",
            );
            const class = vm.mono_funcs.class_from_name(
                image,
                namespace.slice(),
                name.slice(),
            ) orelse return vm.err.set(.{ .missing_class = .{
                .assembly = assembly,
                .namespace = namespace_token.extent(),
                .name = name_token.extent(),
            } });
            (try vm.push(Type)).* = .class;
            (try vm.push(*const mono.Class)).* = class;
        },
    }
}

fn managedId(vm: *Vm, extent: Extent) error{Vm}!ManagedId {
    const len = extent.end - extent.start;
    if (len > ManagedId.max) return vm.err.set(.{ .id_too_big = extent });
    var result: ManagedId = .{ .buf = undefined, .len = @intCast(len) };
    @memcpy(result.buf[0..len], vm.text[extent.start..extent.end]);
    result.buf[len] = 0;
    return result;
}

fn eat(text: []const u8, err: *Error) VmEat {
    return .{ .text = text, .err = err };
}
const VmEat = struct {
    text: []const u8,
    err: *Error,

    fn eatToken(vm: VmEat, start: usize, what: enum {
        l_paren,
        l_brace,
        identifier_from,
    }) error{Vm}!usize {
        const t = lex(vm.text, start);
        const expected_tag: Token.Tag = switch (what) {
            .l_paren => .l_paren,
            .l_brace => .l_brace,
            .identifier_from => .identifier,
        };
        if (t.tag != expected_tag) return vm.err.set(.{ .unexpected_token = .{
            .expected = switch (what) {
                .l_paren => "an open paren '('",
                .l_brace => "an open brace '{'",
                .identifier_from => "the 'from' keyword",
            },
            .token = t,
        } });
        switch (what) {
            .l_paren, .l_brace => {},
            .identifier_from => if (!std.mem.eql(u8, vm.text[t.start..t.end], "from")) return vm.err.set(.{
                .unexpected_token = .{
                    .expected = "the 'from' keyword",
                    .token = t,
                },
            }),
        }
        return t.end;
    }

    pub fn evalBlock(vm: VmEat, start: usize) error{Vm}!usize {
        var offset: usize = start;
        while (true) {
            const after_statement = switch (try vm.evalStatement(offset)) {
                .not_statement => |token| {
                    if (token.tag == .r_brace) return token.end;
                    return vm.err.set(.{ .unexpected_token = .{
                        .expected = "a statement",
                        .token = token,
                    } });
                },
                .statement_end => |end| end,
            };
            std.debug.assert(after_statement > offset);
            offset = after_statement;
        }
    }

    fn evalStatement(vm: VmEat, start: usize) error{Vm}!union(enum) {
        not_statement: Token,
        statement_end: usize,
    } {
        const first_token = lex(vm.text, start);
        switch (first_token.tag) {
            .identifier => {
                const second_token = lex(vm.text, first_token.end);
                if (second_token.tag == .equal) {
                    const expr_first_token = lex(vm.text, second_token.end);
                    const after_expr = try vm.evalExpr(expr_first_token) orelse return vm.err.set(.{ .unexpected_token = .{
                        .expected = "an expresson",
                        .token = expr_first_token,
                    } });
                    return .{ .statement_end = after_expr };
                }
            },
            .keyword_fn => @panic("todo"),
            .keyword_import => @panic("todo"),
            else => {},
        }

        const expr_end = try vm.evalExpr(first_token) orelse return .{ .not_statement = first_token };
        const next_token = lex(vm.text, expr_end);
        if (next_token.tag != .equal) return .{ .statement_end = expr_end };

        @panic("todo");
    }

    fn evalExpr(vm: VmEat, first_token: Token) error{Vm}!?usize {
        var offset = try vm.evalPrimaryTypeExpr(first_token) orelse return null;
        while (true) {
            offset = try vm.evalExprSuffix(offset) orelse return offset;
        }
    }

    fn evalExprSuffix(vm: VmEat, suffix_start: usize) error{Vm}!?usize {
        const suffix_op_token = lex(vm.text, suffix_start);
        return switch (suffix_op_token.tag) {
            .l_bracket => {
                return vm.err.set(.{ .not_implemented = "array index" });
            },
            .period => {
                const id_token = lex(vm.text, suffix_op_token.end);
                if (id_token.tag != .identifier) return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an identifier after '.'",
                    .token = id_token,
                } });
                return id_token.end;
            },
            .l_paren => {
                // var offset = suffix_op_token.end;
                @panic("todo");
            },
            else => null,
        };
    }

    fn evalPrimaryTypeExpr(vm: VmEat, first_token: Token) error{Vm}!?usize {
        return switch (first_token.tag) {
            .identifier,
            .string_literal,
            => return first_token.end,
            .builtin => {
                const next = try vm.eatToken(first_token.end, .l_paren);
                return try vm.evalArgs(next);
            },
            else => null,
        };
    }
    fn evalArgs(vm: VmEat, start: usize) error{Vm}!usize {
        var offset = start;
        while (true) {
            const first_token = lex(vm.text, offset);
            if (first_token.tag == .r_paren) {
                offset = first_token.end;
                break;
            }
            offset = try vm.evalExpr(first_token) orelse return vm.err.set(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } });
            {
                const token = lex(vm.text, offset);
                offset = token.end;
                switch (token.tag) {
                    .r_paren => break,
                    .comma => {},
                    else => return vm.err.set(.{ .unexpected_token = .{
                        .expected = "a ',' or close paren ')'",
                        .token = token,
                    } }),
                }
            }
        }
        return offset;
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
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    std.debug.print("  assembly[{}] name='{s}'\n", .{ ctx.index, std.mem.span(str) });
    // std.log.info("  assembly[{}] name='{s}'", .{ ctx.index, std.mem.span(str) });
}

const Builtin = enum {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // temporary builtin, remove this later
    @"@Nothing",
    @"@LogAssemblies",
    @"@Assembly",
    @"@Class",
    pub fn params(builtin: Builtin) []const Type {
        return switch (builtin) {
            .@"@Nothing" => &.{},
            .@"@LogAssemblies" => &.{},
            .@"@Assembly" => &.{.string_literal},
            .@"@Class" => &.{ .assembly, .string_literal, .string_literal },
        };
    }
    pub fn paramCount(builtin: Builtin) u16 {
        return switch (builtin) {
            inline else => return @intCast(builtin.params().len),
        };
    }
};
pub const builtins = std.StaticStringMap(Builtin).initComptime(.{
    .{ "@Nothing", .@"@Nothing" },
    .{ "@LogAssemblies", .@"@LogAssemblies" },
    .{ "@Assembly", .@"@Assembly" },
    .{ "@Class", .@"@Class" },
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
        number_literal,
        // doc_comment,
        // container_doc_comment,
        keyword_fn,
        keyword_import,
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
        .{ "import", .keyword_import },
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
            .number_literal => try writer.print("a number literal {s}", .{f.text[f.token.start..f.token.end]}),
            .keyword_fn => try writer.writeAll("the 'fn' keyword"),
            .keyword_import => try writer.writeAll("the 'import' keyword"),
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
        int: usize,
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
            .int => |start| .{ .tag = .number_literal, .start = start, .end = index },
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
        try it.expect(.equal, "=");
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
            .num_literal_overflow => |e| try writer.print(
                "{d}: integer literal '{s}' doesn't fit in an i64",
                .{ getLineNum(f.text, e.start), f.text[e.start..e.end] },
            ),
            .called_non_function => |e| if (e.unexpected_type) |t| try writer.print(
                "{d}: can't call {s}",
                .{ getLineNum(f.text, e.start), t.what() },
            ) else try writer.print(
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
            .too_many_args => |e| switch (e.param_count) {
                0 => try writer.print("{d}: function has no parameters", .{
                    getLineNum(f.text, e.pos),
                }),
                1 => try writer.print("{d}: function only accepts 1 parameter", .{
                    getLineNum(f.text, e.pos),
                }),
                else => try writer.print("{d}: function only accepts {} parameters", .{
                    getLineNum(f.text, e.pos),
                    e.param_count,
                }),
            },
            .import_from_non_class => |i| if (i.actual_type) |t| try writer.print(
                "{d}: import from requires a class but got {s}",
                .{ getLineNum(f.text, i.pos), t.what() },
            ) else try writer.print(
                "{d}: import from requires a class but the expression yielded nothing",
                .{getLineNum(f.text, i.pos)},
            ),
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
            .missing_class => |m| try writer.print(
                "{d}: this assembly does not have a class named '{s}' in namespace {s}",
                .{
                    getLineNum(f.text, m.namespace.start),
                    f.text[m.name.start..m.name.end],
                    f.text[m.namespace.start..m.namespace.end],
                },
            ),
            .missing_method => |m| try writer.print(
                "{d}: method {s} with {} params does not exist in this class",
                .{
                    getLineNum(f.text, m.name.start),
                    f.text[m.name.start..m.name.end],
                    m.param_count,
                },
            ),
            .oom => try writer.writeAll("out of memory"),
        }
    }
};

fn testBadCode(text: []const u8, expected_error: []const u8) !void {
    std.debug.print("testing bad code:\n---\n{s}\n---\n", .{text});
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var vm: Vm = .{
        .mono_funcs = &monomock.funcs,
        .mono_domain = undefined,
        .err = undefined,
        .text = text,
        .mem = .{ .allocator = gpa.allocator() },
        .symbols = .{},
    };
    defer vm.deinit();
    if (vm.evalRoot()) {
        return error.TestUnexpectedSuccess;
    } else |_| {
        var buf: [2000]u8 = undefined;
        const actual_error = try std.fmt.bufPrint(&buf, "{f}", .{vm.err.fmt(text)});
        if (!std.mem.eql(u8, expected_error, actual_error)) {
            std.log.err("actual error string\n\"{f}\"\n", .{std.zig.fmtString(actual_error)});
            return error.TestUnexpectedError;
        }
    }
}

test "bad code" {
    try testBadCode("example_id = @Nothing()", "1: nothing was assigned to identifier 'example_id'");
    try testBadCode("fn", "1: syntax error: expected an identifier after 'fn' but got EOF");
    try testBadCode("import", "1: syntax error: expected an identifier after 'import' but got EOF");
    try testBadCode("fn a", "1: syntax error: expected an open paren '(' but got EOF");
    try testBadCode("fn @Nothing()", "1: syntax error: expected an identifier after 'fn' but got the builtin function '@Nothing'");
    try testBadCode("fn foo", "1: syntax error: expected an open paren '(' but got EOF");
    try testBadCode("fn foo \"hello\"", "1: syntax error: expected an open paren '(' but got a string literal \"hello\"");
    try testBadCode("fn foo )", "1: syntax error: expected an open paren '(' but got a close paren ')'");
    try testBadCode("import what 0 fram", "1: syntax error: expected the 'from' keyword but got an identifer 'fram'");
    try testBadCode("import what 0 from", "1: syntax error: expected an expression after 'from' but got EOF");
    try testBadCode("import what 0 from @Nothing()", "1: import from requires a class but the expression yielded nothing");
    try testBadCode("import what 0 from 0", "1: import from requires a class but got an integer");
    try testBadCode("foo()", "1: undefined identifier 'foo'");
    try testBadCode("foo = \"hello\" foo()", "1: can't call a string literal");
    try testBadCode("@Assembly(\"wontbefound\")", "1: assembly \"wontbefound\" not found");
    try testBadCode("mscorlib = @Assembly(\"mscorlib\") mscorlib()", "1: can't call an assembly");
    try testBadCode("fn foo(){}foo.\"wat\"", "1: syntax error: expected an identifier after '.' but got a string literal \"wat\"");
    try testBadCode("@Nothing().foo", "1: void has no fields");
    try testBadCode("fn foo(){}foo.wat", "1: a function has no field 'wat'");
    try testBadCode("@Assembly(\"mscorlib\")()", "1: can't call an assembly");
    // try testCode("@Class(@Assembly(\"mscorlib\"), \"" ++ ("a" ** (dotnet_max_id)) ++ "\")");
    try testBadCode(
        "@Class(@Assembly(\"mscorlib\"), \"System\", \"" ++ ("a" ** (ManagedId.max + 1)) ++ "\")",
        "1: id '" ++ ("a" ** (ManagedId.max + 1)) ++ "' is too big (1024 bytes but max is 1023)",
    );
    try testBadCode(
        "@Class(@Assembly(\"mscorlib\"), \"DoesNot\", \"Exist\")",
        "1: this assembly does not have a class named '\"Exist\"' in namespace \"DoesNot\"",
    );
    try testBadCode("999999999999999999999", "1: integer literal '999999999999999999999' doesn't fit in an i64");
    // try testBadCode("-999999999999999999999", "1: integer literal '-999999999999999999999' doesn't fit in an i64");
    // const max_fields = 256;
    // try testCode("@Assembly(\"mscorlib\")" ++ (".a" ** max_fields));
    // try testBadCode("@Assembly(\"mscorlib\")" ++ (".a" ** (max_fields + 1)), "1: too many assembly fields");

    if (false) try testBadCode(
        \\mscorlib = @Assembly("mscorlib")
        \\console = @Class(mscorlib, "System", "Console")
        \\import writeline 65536 from console
    , "3: method \"WriteLine\" with 9223372036854775807 params does not exist in this class");

    // try testBadCode("fn foo(){}fn foo(){}", "");
    // try testBadCode("fn void foo(){} fn void foo(){}", "");
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
}

fn testCode(text: []const u8) !void {
    std.debug.print("testing code:\n---\n{s}\n---\n", .{text});
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var vm: Vm = .{
        .mono_funcs = &monomock.funcs,
        .mono_domain = undefined,
        .err = undefined,
        .text = text,
        .mem = .{ .allocator = gpa.allocator() },
        .symbols = .{},
    };
    defer vm.deinit();
    vm.evalRoot() catch {
        std.debug.print(
            "Failed to interpret the following code:\n---\n{s}\n---\nerror: {f}\n",
            .{ text, vm.err.fmt(text) },
        );
        return error.VmError;
    };
}

test {
    try testCode("fn foo(){}");
    try testCode("@LogAssemblies()");
    try testCode("fn foo(){ @LogAssemblies() }");
    try testCode("fn foo(){ @LogAssemblies() }foo()foo()");
    try testCode("@Assembly(\"mscorlib\")");
    try testCode("ms = @Assembly(\"mscorlib\")");
    try testCode("\"foo\"");
    try testCode("foo_string = \"foo\"");
    try testCode("fn foo(){}foo");
    try testCode("fn foo(){}foo()");
    // try testCode("\"foo\"[0]");
    // try testCode(".foo");
    // try testCode("@Assembly(\"mscorlib\") =");
    // try testCode("fn foo(){}foo.bar");

    // try testCode("@Assembly(\"mscorlib\").Class");

    // try testCode("@Assembly(\"mscorlib\").System.Console()");
    if (false) try testCode(
        \\mscorlib = @Assembly("mscorlib")
        \\console = @Class(mscorlib, "System", "Console")
        \\import Beep 0 from console
        \\Beep
        \\//import WriteLine 0 from console
        \\//WriteLine()
    );
}

const std = @import("std");
const mono = @import("mono.zig");
const monomock = @import("monomock.zig");
const Memory = @import("Memory.zig");
