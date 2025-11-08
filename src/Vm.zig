const Vm = @This();

mono_funcs: *const mono.Funcs,
err: Error,
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
    vm.mem.deinit();
    vm.* = undefined;
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

pub fn evalRoot(vm: *Vm) error{Vm}!void {
    std.debug.assert(vm.mem.top().eql(.zero));

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

pub fn evalFunction(
    vm: *Vm,
    start: usize,
    return_storage: *ReturnStorage,
    args_addr: Memory.Addr,
) error{Vm}!usize {
    const body_start = blk: {
        const token = lex(vm.text, start);
        if (token.tag != .l_brace) return vm.err.set(.{ .unexpected_token = .{
            .expected = "an open brace '{' to start function body",
            .token = token,
        } });
        break :blk token.end;
    };

    const after_close_brace = blk: {
        var offset: usize = body_start;
        while (true) {
            const after_statement = switch (try vm.evalStatement(offset)) {
                .not_statement => |token| {
                    if (token.tag == .r_brace) break :blk token.end;
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
    };

    _ = return_storage;
    if (!args_addr.eql(vm.mem.top())) return vm.err.set(.{ .not_implemented = "evalFunction stack cleanup" });
    return after_close_brace;
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
                try vm.startSymbol(first_token.start);
                const value_addr = vm.mem.top();
                const expr_first_token = lex(vm.text, second_token.end);
                const after_expr = try vm.evalExpr(expr_first_token) orelse return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an expresson",
                    .token = expr_first_token,
                } });
                if (value_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_assignment = .{
                    .id_extent = first_token.extent(),
                } });
                try vm.endSymbol();
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
            const arg_start = blk: {
                const token = lex(vm.text, id_extent.end);
                if (token.tag != .l_paren) return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an open paren '(' to start function args",
                    .token = token,
                } });
                break :blk token.end;
            };
            const params = try eat(vm.text, &vm.err).evalParamDeclList(arg_start);
            const after_definition = try eat(vm.text, &vm.err).evalFunction(params.end);

            try vm.startSymbol(id_extent.start);
            (try vm.push(Type)).* = .script_function;
            (try vm.push(usize)).* = arg_start;
            try vm.endSymbol();
            return .{ .statement_end = after_definition };
        },
        else => {},
    }

    const expr_addr = vm.mem.top();
    const expr_end = try vm.evalExpr(first_token) orelse return .{ .not_statement = first_token };
    const next_token = lex(vm.text, expr_end);
    if (next_token.tag != .equal) {
        if (!vm.mem.top().eql(expr_addr)) {
            const expr_type, _ = vm.readValue(Type, expr_addr);
            return vm.err.set(.{ .statement_result_ignored = .{
                .pos = first_token.start,
                .ignored_type = expr_type,
            } });
        }
        return .{ .statement_end = expr_end };
    }

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
            const expr_type_ptr, const value_addr = vm.readPointer(Type, expr_addr);
            return switch (expr_type_ptr.*) {
                .integer,
                .string_literal,
                .script_function,
                => vm.err.set(.{ .no_field = .{
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
                    // if (lexClass(vm.text, &namespace, &name, id_start)) |too_big_end| return vm.err.set(.{
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
                    return vm.err.set(.{ .not_implemented = "class member" });
                },
                .object => vm.err.set(.{ .not_implemented = "object fields" }),
            };
        },
        .l_paren => {
            if (expr_addr.eql(vm.mem.top())) return vm.err.set(.{ .called_non_function = .{
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
                            return vm.err.set(.{ .not_implemented = "class member with multiple '.IDENTIFIER'" });
                        }
                        break :blk previous;
                    };
                    const method_id = try vm.managedId(method_id_extent);
                    // const method = vm.mono_funcs.class_get_method_form_name
                    // if (true) std.debug.panic("TODO: call '{s}'\n", .{method_id});

                    const args_addr = vm.mem.top();
                    const args = try vm.evalFnCallArgsManaged(suffix_op_token.end);

                    const method = vm.mono_funcs.class_get_method_from_name(
                        member.class,
                        method_id.slice(),
                        args.count,
                    ) orelse return vm.err.set(.{ .missing_method = .{
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
                    if (args.count == 0) {
                        std.debug.assert(args_addr.eql(vm.mem.top()));
                        // TODO: add check that scans to see if anyone is pointing to discarded memory?
                        // _ = vm.mem.discardFrom(expr_addr);
                    } else {
                        return vm.err.set(.{ .not_implemented = "call method with args" });
                    }

                    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                    // TODO: how do we know if we need an object
                    const object: ?*anyopaque = null;
                    const params: ?**anyopaque = null;
                    var maybe_exception: ?*const mono.Object = null;

                    const maybe_result = vm.mono_funcs.runtime_invoke(
                        method,
                        object,
                        params,
                        &maybe_exception,
                    );
                    if (false) std.debug.print(
                        "Result=0x{x} Exception=0x{x}\n",
                        .{ @intFromPtr(maybe_result), @intFromPtr(maybe_exception) },
                    );
                    if (maybe_exception) |e| {
                        std.log.err("TODO: handle exception 0x{x}\n", .{@intFromPtr(e)});
                        return vm.err.set(.{ .not_implemented = "handle exception" });
                    }
                    switch (vm.mono_funcs.type_get_type(return_type)) {
                        .void => if (maybe_result) |_| {
                            return vm.err.set(.{ .not_implemented = "error message for calling managed function with void return type that returned something" });
                        },
                        .i4 => {
                            const result = maybe_result orelse return vm.err.set(.{ .not_implemented = "error message for calling managed function with i4 return type that returned null" });
                            const unboxed: *align(1) i32 = @ptrCast(vm.mono_funcs.object_unbox(result));
                            std.log.info("Unboxed 32-bit return value {} (0x{0x})", .{unboxed.*});
                            (try vm.push(Type)).* = .integer;
                            (try vm.push(i64)).* = unboxed.*;
                        },
                        else => |kind| {
                            std.debug.print("ReturnTypeKind={t}\n", .{kind});
                            return vm.err.set(.{ .not_implemented = "managed return value of this type" });
                        },
                    }
                    return args.end;
                },
                .script_function => |param_start| {
                    const params = try eat(vm.text, &vm.err).evalParamDeclList(param_start);
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
                        return vm.err.set(.{ .not_implemented = "function calls with return types" });
                    }
                    return after_args;
                },
                else => |value| return vm.err.set(.{ .called_non_function = .{
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
            return vm.err.set(.{ .not_implemented = "pushValueFromAddr assembly_field" });
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
            return vm.err.set(.{ .not_implemented = "pushValueFromAddr assembly_field" });
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
            const entry = vm.lookup(string) orelse return vm.err.set(
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
            const builtin = builtin_map.get(id) orelse return vm.err.set(.{ .unknown_builtin = first_token });
            const next = try eat(vm.text, &vm.err).eatToken(first_token.end, .l_paren);
            const args_addr = vm.mem.top();
            const args_end = try vm.evalFnCallArgs(.{ .builtin = builtin.params() }, next);
            try vm.evalBuiltin(first_token.extent(), builtin, args_addr);
            return args_end;
        },
        .number_literal => {
            const str = vm.text[first_token.start..first_token.end];
            const value = std.fmt.parseInt(i64, str, 10) catch |err| switch (err) {
                error.Overflow => return vm.err.set(.{ .num_literal_overflow = first_token.extent() }),
                error.InvalidCharacter => return vm.err.set(.{ .bad_num_literal = first_token.extent() }),
            };
            (try vm.push(Type)).* = .integer;
            (try vm.push(i64)).* = value;
            return first_token.end;
        },
        .keyword_new => {
            @panic("todo");
            // const id_extent = blk: {
            //     const token = lex(vm.text, first_token.end);
            //     if (token.tag != .identifier) return vm.err.set(.{ .unexpected_token = .{
            //         .expected = "an identifier to follow 'new'",
            //         .token = token,
            //     } });
            //     break :blk token.extent();
            // };
            // const id_string = vm.text[id_extent.start..id_extent.end];
            // const symbol = vm.lookup(id_string) orelse return vm.err.set(
            //     .{ .undefined_identifier = id_extent },
            // );
            // const symbol_type, const value_addr = vm.readValue(Type, symbol.value_addr);
            // if (symbol_type != .class) return vm.err.set(.{ .new_non_class = .{
            //     .id_extent = id_extent,
            //     .actual_type = symbol_type,
            // } });
            // _ = value_addr;

            // const next = try eat(vm.text, &vm.err).eatToken(id_extent.end, .l_paren);
            // _ = next;
            // // const args_addr = vm.mem.top();
            // // const args_end = try vm.evalFnCallArgs(builtin.paramCount(), .{ .builtin = builtin.params() }, next);
            // return vm.err.set(.{ .not_implemented = "new expression" });
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
        text_offset = try vm.evalExpr(first_token) orelse return vm.err.set(.{ .unexpected_token = .{
            .expected = "an expression",
            .token = first_token,
        } });
        if (arg_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_argument = .{
            .arg_index = arg_index,
            .first_arg_token = first_token,
        } });

        {
            // should we perform any checks
            const arg_type = vm.mem.toPointer(Type, arg_addr).*;
            if (!arg_type.canMarshal()) return vm.err.set(.{ .cant_marshal = .{
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
            else => return vm.err.set(.{ .unexpected_token = .{
                .expected = "a ',' or close paren ')'",
                .token = second_token,
            } }),
        }
    }
}

const Params = union(enum) {
    builtin: []const BuiltinParamType,
    script: u16,
    pub fn count(params: Params) u16 {
        return switch (params) {
            .builtin => |types| @intCast(types.len),
            .script => |c| c,
        };
    }
    pub fn expectedType(params: Params, arg_index: u16) ?Type {
        return switch (params) {
            .builtin => |param_types| if (arg_index < param_types.len) switch (param_types[arg_index]) {
                .anything => null,
                .concrete => |t| t,
            } else null,
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
        if (arg_index < params.count()) {
            const arg_addr = vm.mem.top();
            text_offset = try vm.evalExpr(first_token) orelse return vm.err.set(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } });
            if (arg_addr.eql(vm.mem.top())) return vm.err.set(.{ .void_argument = .{
                .arg_index = arg_index,
                .first_arg_token = first_token,
            } });
            const arg_type = vm.mem.toPointer(Type, arg_addr).*;
            if (params.expectedType(arg_index)) |t| if (t != arg_type) return vm.err.set(.{ .arg_type = .{
                .arg_pos = first_token.start,
                .arg_index = arg_index,
                .expected = t,
                .actual = arg_type,
            } });
        } else {
            text_offset = try eat(vm.text, &vm.err).evalExpr(first_token) orelse return vm.err.set(.{ .unexpected_token = .{
                .expected = "an expression",
                .token = first_token,
            } });
        }

        if (arg_index == std.math.maxInt(u16)) return vm.err.set(.{ .arg_count = .{
            .start = start,
            .expected = params.count(),
            .actual = @as(u17, std.math.maxInt(u16)) + 1,
        } });
        arg_index += 1;

        {
            const token = lex(vm.text, text_offset);
            text_offset = token.end;
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
    if (arg_index != params.count()) return vm.err.set(.{ .arg_count = .{
        .start = start,
        .expected = params.count(),
        .actual = arg_index,
    } });
    return text_offset;
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
            const match = context.match orelse return vm.err.set(
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
            if (lexClass(vm.text, &namespace, &name, field.id_start)) |too_big_end| return vm.err.set(.{
                .id_too_big = .{ .start = field.id_start, .end = too_big_end },
            });
            const image = vm.mono_funcs.assembly_get_image(field.assembly) orelse @panic(
                "mono_assembly_get_image returned null",
            );
            const class = vm.mono_funcs.class_from_name(
                image,
                namespace.slice(),
                name.slice(),
            ) orelse return vm.err.set(.{ .missing_class = .{
                .assembly = field.assembly,
                .id_start = field.id_start,
            } });
            (try vm.push(Type)).* = .class;
            (try vm.push(*const mono.Class)).* = class;
        },
        .@"@Discard" => {
            var value = vm.pop(args_addr);
            value.discard();
        },
        .@"@ScheduleTests" => {
            vm.tests_scheduled = true;
        },
    }
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
        id_addr = previous_id_addr;
    }
    return null;
}

fn push(vm: *Vm, comptime T: type) error{Vm}!*T {
    return vm.mem.push(T) catch return vm.err.set(.oom);
}
fn pop(vm: *Vm, addr: Memory.Addr) Value {
    const value_type, const value_addr = vm.readValue(Type, addr);
    switch (value_type) {
        .integer => {
            const value, const end = vm.readValue(i64, value_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            return .{ .integer = value };
        },
        .string_literal => {
            const start, const end = vm.readValue(usize, value_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            std.debug.assert(vm.text[start] == '"');
            const token = lex(vm.text, start);
            std.debug.assert(token.start == start);
            std.debug.assert(token.tag == .string_literal);
            std.debug.assert(vm.text[token.end - 1] == '"');
            return .{ .string_literal = token.extent() };
        },
        .script_function => {
            const param_start, const end = vm.readValue(usize, value_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            return .{ .script_function = param_start };
        },
        .assembly => {
            const assembly, const end = vm.readValue(*const mono.Assembly, value_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            return .{ .assembly = assembly };
        },
        .assembly_field => {
            const assembly, const id_start_addr = vm.readValue(*const mono.Assembly, value_addr);
            const id_start, var end = vm.readValue(usize, id_start_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            return .{ .assembly_field = .{
                .assembly = assembly,
                .id_start = id_start,
            } };
        },
        .class => {
            const class, const end = vm.readValue(*const mono.Class, value_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            return .{ .class = class };
        },
        .class_member => {
            const class, const id_start_addr = vm.readValue(*const mono.Class, value_addr);
            const id_start, var end = vm.readValue(usize, id_start_addr);
            std.debug.assert(end.eql(vm.mem.top()));
            // TODO: add check that scans to see if anyone is pointing to discarded memory?
            _ = vm.mem.discardFrom(addr);
            return .{ .class_member = .{
                .class = class,
                .id_start = id_start,
            } };
        },
        else => |t| std.debug.panic("todo: implement pop for type '{s}'", .{@tagName(t)}),
    }
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
    pub fn discard(value: *Value) void {
        switch (value.*) {
            .integer => {},
            .string_literal => {},
            .script_function => {},
            .assembly => {},
            .assembly_field => {},
            .class => {},
            .class_member => {},
        }
    }
    pub fn getType(value: *const Value) Type {
        return switch (value.*) {
            .integer => .integer,
            .string_literal => .string_literal,
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
        identifier,
        identifier_from,
    }) error{Vm}!usize {
        const t = lex(vm.text, start);
        const expected_tag: Token.Tag = switch (what) {
            .l_paren => .l_paren,
            .l_brace => .l_brace,
            .identifier => .identifier,
            .identifier_from => .identifier,
        };
        if (t.tag != expected_tag) return vm.err.set(.{ .unexpected_token = .{
            .expected = switch (what) {
                .l_paren => "an open paren '('",
                .l_brace => "an open brace '{'",
                .identifier => "an identifier",
                .identifier_from => "the 'from' keyword",
            },
            .token = t,
        } });
        switch (what) {
            .l_paren, .l_brace, .identifier => {},
            .identifier_from => if (!std.mem.eql(u8, vm.text[t.start..t.end], "from")) return vm.err.set(.{
                .unexpected_token = .{
                    .expected = "the 'from' keyword",
                    .token = t,
                },
            }),
        }
        return t.end;
    }

    pub fn evalFunction(vm: VmEat, start: usize) error{Vm}!usize {
        const body_start = blk: {
            const token = lex(vm.text, start);
            if (token.tag != .l_brace) return vm.err.set(.{ .unexpected_token = .{
                .expected = "an open brace '{' to start function body",
                .token = token,
            } });
            break :blk token.end;
        };

        var offset: usize = body_start;
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
                const after_l_paren = try vm.eatToken(first_token.end, .l_paren);
                return try vm.evalFnCallArgs(after_l_paren);
            },
            .keyword_new => {
                const after_id = try vm.eatToken(first_token.end, .identifier);
                const after_l_paren = try vm.eatToken(after_id, .l_paren);
                return try vm.evalFnCallArgs(after_l_paren);
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
                else => return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an identifier or close paren ')'",
                    .token = first_token,
                } }),
            }
            if (param_count == std.math.maxInt(u16)) return vm.err.set(.{ .not_implemented = "more than 65535 args" });
            param_count += 1;
            const second_token = lex(vm.text, offset);
            offset = second_token.end;
            switch (second_token.tag) {
                .r_paren => return .{ .count = param_count, .end = second_token.end },
                .comma => {},
                else => return vm.err.set(.{ .unexpected_token = .{
                    .expected = "an comma ',' or close paren ')'",
                    .token = first_token,
                } }),
            }
        }
    }
};

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
    @"@LogAssemblies",
    @"@Assembly",
    @"@Class",
    @"@Discard",
    //
    @"@ScheduleTests",
    pub fn params(builtin: Builtin) []const BuiltinParamType {
        return switch (builtin) {
            .@"@Nothing" => &.{},
            .@"@LogAssemblies" => &.{},
            .@"@Assembly" => &.{.{ .concrete = .string_literal }},
            .@"@Class" => &.{.{ .concrete = .assembly_field }},
            .@"@Discard" => &.{.anything},
            .@"@ScheduleTests" => &.{},
        };
    }
};
pub const builtin_map = std.StaticStringMap(Builtin).initComptime(.{
    .{ "@Nothing", .@"@Nothing" },
    .{ "@LogAssemblies", .@"@LogAssemblies" },
    .{ "@Assembly", .@"@Assembly" },
    .{ "@Class", .@"@Class" },
    .{ "@Discard", .@"@Discard" },
    .{ "@ScheduleTests", .@"@ScheduleTests" },
});

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
        keyword_new,
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
            .keyword_new => try writer.writeAll("the 'new' keyword"),
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

const MethodNameKind = enum { id, new };

pub const Error = union(enum) {
    not_implemented: [:0]const u8,
    unexpected_token: struct { expected: [:0]const u8, token: Token },
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
    new_non_class: struct {
        id_extent: Extent,
        actual_type: Type,
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
    statement_result_ignored: struct {
        pos: usize,
        ignored_type: Type,
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
            .new_non_class => |n| try writer.print(
                "{d}: cannot new '{s}' which is {s}",
                .{
                    getLineNum(f.text, n.id_extent.start),
                    f.text[n.id_extent.start..n.id_extent.end],
                    n.actual_type.what(),
                },
            ),
            .needed_type => |n| try writer.print(
                "{d}: expected a {s} type but got {s}",
                .{
                    getLineNum(f.text, lex(f.text, n.pos).start),
                    @tagName(n.context),
                    @tagName(n.value),
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
        .err = undefined,
        .text = text,
        .mem = .{ .allocator = vm_fixed_fba.allocator() },
    };
    vm.verifyStack();
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

fn badCodeTests(mono_funcs: *const mono.Funcs) !void {
    try testBadCode(mono_funcs, "example_id = @Nothing()", "1: nothing was assigned to identifier 'example_id'");
    try testBadCode(mono_funcs, "fn", "1: syntax error: expected an identifier after 'fn' but got EOF");
    try testBadCode(mono_funcs, "fn @Nothing()", "1: syntax error: expected an identifier after 'fn' but got the builtin function '@Nothing'");
    try testBadCode(mono_funcs, "fn foo", "1: syntax error: expected an open paren '(' to start function args but got EOF");
    try testBadCode(mono_funcs, "fn foo \"hello\"", "1: syntax error: expected an open paren '(' to start function args but got a string literal \"hello\"");
    try testBadCode(mono_funcs, "fn foo )", "1: syntax error: expected an open paren '(' to start function args but got a close paren ')'");
    try testBadCode(mono_funcs, "foo()", "1: undefined identifier 'foo'");
    try testBadCode(mono_funcs, "foo = \"hello\" foo()", "1: can't call a string literal");
    try testBadCode(mono_funcs, "@Assembly(\"wontbefound\")", "1: assembly \"wontbefound\" not found");
    try testBadCode(mono_funcs, "mscorlib = @Assembly(\"mscorlib\") mscorlib()", "1: can't call an assembly");
    try testBadCode(mono_funcs, "fn foo(){}foo.\"wat\"", "1: syntax error: expected an identifier after '.' but got a string literal \"wat\"");
    try testBadCode(mono_funcs, "@Nothing().foo", "1: void has no fields");
    try testBadCode(mono_funcs, "fn foo(){}foo.wat", "1: a function has no field 'wat'");
    try testBadCode(mono_funcs, "@Assembly(\"mscorlib\")()", "1: can't call an assembly");
    // try testCode("@Class(@Assembly(\"mscorlib\"), \"" ++ ("a" ** (dotnet_max_id)) ++ "\")");
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
        \\mscorlib = @Assembly("mscorlib")
        \\Console = @Class(mscorlib.System.Console)
        \\fn foo() {}
        \\Console.Write(foo);
    , "4: can't marshal a function to a managed method");
    try testBadCode(mono_funcs,
        \\mscorlib = @Assembly("mscorlib")
        \\Console = @Class(mscorlib.System.Console)
        \\Console.ThisMethodShouldNotExist();
    , "3: method ThisMethodShouldNotExist with 0 params does not exist in this class");
    try testBadCode(mono_funcs, "0", "1: return value of type integer was ignored, use @Discard to discard it");
    try testBadCode(mono_funcs, "\"hello\"", "1: return value of type string_literal was ignored, use @Discard to discard it");
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
        .err = undefined,
        .text = text,
        .mem = .{ .allocator = vm_fixed_fba.allocator() },
    };
    vm.verifyStack();
    vm.evalRoot() catch {
        std.debug.print(
            "Failed to interpret the following code:\n---\n{s}\n---\nerror: {f}\n",
            .{ text, vm.err.fmt(text) },
        );
        return error.VmError;
    };
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
        \\mscorlib = @Assembly("mscorlib")
        \\@Discard(@Class(mscorlib.System.Object))
    );
    try testCode(mono_funcs, "ms = @Assembly(\"mscorlib\")");
    try testCode(mono_funcs, "foo_string = \"foo\"");
    try testCode(mono_funcs, "fn foo(){}@Discard(foo)");
    try testCode(mono_funcs, "fn foo(){}foo()");
    // try testCode(mono_funcs, "\"foo\"[0]");
    // try testCode(mono_funcs, "@Assembly(\"mscorlib\") =");
    try testCode(mono_funcs, "fn foo(x) { }");
    // try testCode(mono_funcs, "fn foo(x) { }foo(0)");
    // try testCode(mono_funcs, "fn foo(x,y) { }foo(0,1)");
    if (false) try testCode(mono_funcs,
        \\fn fib(n) {
        \\  if (n <= 1) return n
        \\  return fib(n - 1) + fib(n - 1)
        \\}
        \\fib(10)
    );
    try testCode(mono_funcs,
        \\mscorlib = @Assembly("mscorlib")
        \\Object = @Class(mscorlib.System.Object)
        \\//mscorlib.System.Console.WriteLine()
        \\//mscorlib.System.Console.Beep()
        \\//example_obj = new Object()
        \\
    );
    try testCode(mono_funcs,
        \\mscorlib = @Assembly("mscorlib")
        \\Console = @Class(mscorlib.System.Console)
        \\Console.Beep()
        \\Console.WriteLine()
        \\//Console.WriteLine("Hello")
        \\Environment = @Class(mscorlib.System.Environment)
        \\//@Discard(Environment.get_TickCount())
        \\//@Discard(Environment.get_MachineName())
        \\
        \\//sys = @Assembly("System")
        \\//Stopwatch = @Class(sys.System.Diagnostics.Stopwatch)
    );
}

const is_test = @import("builtin").is_test;

const std = @import("std");
const mono = @import("mono.zig");
const monomock = if (is_test) @import("monomock.zig") else struct {};
const Memory = @import("Memory.zig");
