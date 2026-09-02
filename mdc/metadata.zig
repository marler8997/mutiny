// The ECMA-335 half of mdc: the metadata tables, the heaps and the IL bodies, built from
// symbolic directives. Heap layout is not written in the source - entries are interned on
// first use, in the same pass order csc uses, so the heaps come out byte-identical. The
// passes are numbered in finish(); the calibration lives in the order of those passes and
// in the order each helper interns what it touches.
//
// Things csc invents during compilation rather than reading from source - the <Module>
// typedef, default .ctor bodies aside, the .cctor, and the array-initializer machinery
// (<PrivateImplementationDetails>, its nested struct and field) - intern late, during body
// emission. The source marks those 'synthetic' so mdc knows to defer them.

pub const Model = struct {
    arena: std.mem.Allocator,
    path: []const u8,

    module_name: ?[]const u8 = null,
    typerefs: std.ArrayListUnmanaged(TypeRef) = .{},
    typedefs: std.ArrayListUnmanaged(TypeDef) = .{},
    fields: std.ArrayListUnmanaged(Field) = .{},
    methods: std.ArrayListUnmanaged(Method) = .{},
    params: std.ArrayListUnmanaged(Param) = .{},
    memberrefs: std.ArrayListUnmanaged(MemberRef) = .{},
    custom_attributes: std.ArrayListUnmanaged(CustomAttribute) = .{},
    class_layouts: std.ArrayListUnmanaged(ClassLayout) = .{},
    field_rvas: std.ArrayListUnmanaged(FieldRva) = .{},
    assembly: ?Assembly = null,
    assemblyrefs: std.ArrayListUnmanaged(AssemblyRef) = .{},
    nested_classes: std.ArrayListUnmanaged(NestedClass) = .{},

    datas: std.ArrayListUnmanaged(Data) = .{},
    open_method: ?u32 = null,
    // the 1-based declared indexes of the typedef blocks currently open
    typedef_stack: std.ArrayListUnmanaged(u16) = .{},

    // typeref and memberref directives are imports: they say where a name lives and what
    // shape it has, and a table row appears only when something actually uses one
    const TypeRef = struct { scope: []const u8, ns: []const u8, name: []const u8 };
    const TypeDef = struct {
        name: []const u8,
        ns: []const u8,
        flags: u32,
        extends: []const u8,
        synthetic: bool,
        fields_start: u16,
        methods_start: u16,
    };
    const Field = struct {
        owner: u16,
        name: []const u8,
        flags: u16,
        sig: []const u8,
        constant: ?[]const u8,
    };
    const Method = struct {
        owner: u16,
        name: []const u8,
        flags: u16,
        sig: []const u8,
        synthetic: bool,
        params_start: u16,
        locals: ?[]const u8 = null,
        instructions: std.ArrayListUnmanaged([]const u8) = .{},
    };
    const Param = struct { seq: u16, name: []const u8 };
    const MemberRef = struct { class: []const u8, name: []const u8, sig: []const u8 };
    const CustomAttribute = struct { parent: []const u8, ctor: []const u8, value: []const u8 };
    const ClassLayout = struct { parent: []const u8, packing: u16, size: u32 };
    const FieldRva = struct { field: []const u8, data: []const u8 };
    const Assembly = struct { name: []const u8, version: [4]u16 };
    const AssemblyRef = struct { name: []const u8, version: [4]u16, keytoken: []const u8 };
    const NestedClass = struct { nested: u16, enclosing: u16 };
    const Data = struct { name: []const u8, content: []const u8 };

    fn openTypeDef(m: *Model) u16 {
        if (m.typedef_stack.items.len == 0) return 0;
        return m.typedef_stack.items[m.typedef_stack.items.len - 1];
    }
};

pub fn directive(
    m: *Model,
    path: []const u8,
    lineno: u32,
    name: []const u8,
    rest: []const u8,
) bool {
    m.path = path;
    if (m.open_method) |method_index| {
        if (std.mem.eql(u8, name, "}")) {
            m.open_method = null;
            return true;
        }
        const method = &m.methods.items[method_index];
        if (std.mem.eql(u8, name, "locals")) {
            if (method.instructions.items.len > 0) errExit(
                "{s}:{}: locals after the first instruction",
                .{ path, lineno },
            );
            if (method.locals != null) errExit("{s}:{}: second locals", .{ path, lineno });
            method.locals = dupe(m, rest);
            return true;
        }
        const line = dupe(m, std.mem.trim(u8, joinLine(name, rest), " \t"));
        method.instructions.append(m.arena, line) catch |err| errExit("{t}", .{err});
        return true;
    }
    if (std.mem.eql(u8, name, "}")) {
        if (rest.len > 0) errExit("{s}:{}: trailing '{s}'", .{ path, lineno, rest });
        if (m.typedef_stack.items.len == 0) errExit("{s}:{}: unmatched '}}'", .{ path, lineno });
        m.typedef_stack.items.len -= 1;
        return true;
    }
    if (std.mem.eql(u8, name, "module")) {
        if (m.module_name != null) errExit("{s}:{}: second module", .{ path, lineno });
        var it = rest;
        m.module_name = dupe(m, parseQuoted(path, lineno, requireArg(path, lineno, &it)));
    } else if (std.mem.eql(u8, name, "typeref")) {
        var it = rest;
        m.typerefs.append(m.arena, .{
            .scope = dupe(m, requireArg(path, lineno, &it)),
            .ns = dupe(m, requireArg(path, lineno, &it)),
            .name = dupe(m, requireArg(path, lineno, &it)),
        }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "typedef")) {
        var it = stripOpenBrace(path, lineno, rest);
        const type_name = dupe(m, unquote(requireArg(path, lineno, &it)));
        const ns = dupe(m, unquote(requireArg(path, lineno, &it)));
        var flags: u32 = 0;
        var extends: []const u8 = "";
        var synthetic = false;
        while (nextArg(&it)) |arg| {
            if (std.mem.eql(u8, arg, "extends")) {
                extends = dupe(m, requireArg(path, lineno, &it));
            } else if (std.mem.eql(u8, arg, "synthetic")) {
                synthetic = true;
            } else flags |= typedefFlag(path, lineno, arg);
        }
        m.typedefs.append(m.arena, .{
            .name = type_name,
            .ns = ns,
            .flags = flags,
            .extends = extends,
            .synthetic = synthetic,
            .fields_start = @intCast(m.fields.items.len + 1),
            .methods_start = @intCast(m.methods.items.len + 1),
        }) catch |err| errExit("{t}", .{err});
        const declared: u16 = @intCast(m.typedefs.items.len);
        // a typedef block inside a typedef block is a nested class
        if (m.openTypeDef() != 0) m.nested_classes.append(m.arena, .{
            .nested = declared,
            .enclosing = m.openTypeDef(),
        }) catch |err| errExit("{t}", .{err});
        m.typedef_stack.append(m.arena, declared) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "field")) {
        if (m.openTypeDef() == 0) errExit("{s}:{}: field outside a typedef block", .{ path, lineno });
        var it = rest;
        const field_name = dupe(m, unquote(requireArg(path, lineno, &it)));
        var flags: u16 = 0;
        while (true) {
            var peek = it;
            const arg = nextArg(&peek) orelse errExit("{s}:{}: field without a type", .{ path, lineno });
            const flag = fieldFlag(arg) orelse break;
            flags |= flag;
            it = peek;
        }
        var constant: ?[]const u8 = null;
        var sig = it;
        if (std.mem.indexOf(u8, it, " = ")) |eq| {
            sig = std.mem.trim(u8, it[0..eq], " \t");
            constant = dupe(m, std.mem.trim(u8, it[eq + 3 ..], " \t"));
        }
        m.fields.append(m.arena, .{
            .owner = m.openTypeDef(),
            .name = field_name,
            .flags = flags,
            .sig = dupe(m, sig),
            .constant = constant,
        }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "method")) {
        if (m.openTypeDef() == 0) errExit("{s}:{}: method outside a typedef block", .{ path, lineno });
        var it = stripOpenBrace(path, lineno, rest);
        const method_name = dupe(m, requireArg(path, lineno, &it));
        var flags: u16 = 0;
        var synthetic = false;
        while (true) {
            var peek = it;
            const arg = nextArg(&peek) orelse errExit("{s}:{}: method without a signature", .{ path, lineno });
            if (arg[0] == '(' or std.mem.eql(u8, arg, "instance")) break;
            if (std.mem.eql(u8, arg, "synthetic")) {
                synthetic = true;
            } else flags |= methodFlag(path, lineno, arg);
            it = peek;
        }
        addMethod(m, path, lineno, method_name, flags, synthetic, it);
    } else if (std.mem.eql(u8, name, "ctor") or std.mem.eql(u8, name, "cctor")) {
        if (m.openTypeDef() == 0) errExit("{s}:{}: {s} outside a typedef block", .{ path, lineno, name });
        const is_cctor = name[0] == 'c' and name[1] == 'c';
        var flags: u16 = 0x80 | 0x800 | 0x1000; // hidebysig specialname rtspecialname
        var synthetic = false;
        var it = stripOpenBrace(path, lineno, rest);
        while (nextArg(&it)) |arg| {
            if (std.mem.eql(u8, arg, "synthetic")) {
                synthetic = true;
            } else flags |= methodFlag(path, lineno, arg);
        }
        if (is_cctor) flags |= 0x1 | 0x10; // private static
        addMethod(
            m,
            path,
            lineno,
            if (is_cctor) ".cctor" else ".ctor",
            flags,
            synthetic,
            if (is_cctor) "( ) void" else "instance ( ) void",
        );
    } else if (std.mem.eql(u8, name, "memberref")) {
        var it = rest;
        const class = dupe(m, requireArg(path, lineno, &it));
        const member = dupe(m, requireArg(path, lineno, &it));
        const sig, const trailing = parseMethodSig(m, path, lineno, it, false);
        if (trailing.len > 0) errExit("{s}:{}: trailing '{s}'", .{ path, lineno, trailing });
        m.memberrefs.append(m.arena, .{
            .class = class,
            .name = member,
            .sig = sig,
        }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "customattribute")) {
        var it = rest;
        const first = dupe(m, unquote(requireArg(path, lineno, &it)));
        // inside a typedef block the parent is implied, so the first argument is the ctor
        var parent = first;
        var ctor = first;
        if (std.mem.indexOf(u8, first, "::") != null) {
            const open = m.openTypeDef();
            if (open == 0) errExit(
                "{s}:{}: customattribute without a parent outside a typedef block",
                .{ path, lineno },
            );
            parent = m.typedefs.items[open - 1].name;
        } else {
            ctor = dupe(m, requireArg(path, lineno, &it));
        }
        m.custom_attributes.append(m.arena, .{
            .parent = parent,
            .ctor = ctor,
            .value = dupe(m, it),
        }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "classlayout")) {
        var it = rest;
        const parent = dupe(m, unquote(requireArg(path, lineno, &it)));
        const packing = parseInt(u16, path, lineno, requireArg(path, lineno, &it));
        const size = parseInt(u32, path, lineno, requireArg(path, lineno, &it));
        m.class_layouts.append(m.arena, .{
            .parent = parent,
            .packing = packing,
            .size = size,
        }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "fieldrva")) {
        var it = rest;
        const field = dupe(m, unquote(requireArg(path, lineno, &it)));
        const data = dupe(m, requireArg(path, lineno, &it));
        m.field_rvas.append(m.arena, .{ .field = field, .data = data }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "assembly")) {
        if (m.assembly != null) errExit("{s}:{}: second assembly", .{ path, lineno });
        var it = rest;
        m.assembly = .{
            .name = dupe(m, parseQuoted(path, lineno, requireArg(path, lineno, &it))),
            .version = parseVersion(path, lineno, requireArg(path, lineno, &it)),
        };
    } else if (std.mem.eql(u8, name, "assemblyref")) {
        var it = rest;
        const ref_name = dupe(m, requireArg(path, lineno, &it));
        const version = parseVersion(path, lineno, requireArg(path, lineno, &it));
        const kw = requireArg(path, lineno, &it);
        if (!std.mem.eql(u8, kw, "keytoken")) errExit("{s}:{}: expected 'keytoken'", .{ path, lineno });
        m.assemblyrefs.append(m.arena, .{
            .name = ref_name,
            .version = version,
            .keytoken = dupe(m, requireArg(path, lineno, &it)),
        }) catch |err| errExit("{t}", .{err});
    } else if (std.mem.eql(u8, name, "data")) {
        var it = rest;
        const data_name = dupe(m, requireArg(path, lineno, &it));
        const kind = requireArg(path, lineno, &it);
        if (!std.mem.eql(u8, kind, "i4")) errExit("{s}:{}: only i4 data", .{ path, lineno });
        var content: std.ArrayListUnmanaged(u8) = .{};
        while (nextArg(&it)) |arg| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &buf, parseInt(i32, path, lineno, arg), .little);
            content.appendSlice(m.arena, &buf) catch |err| errExit("{t}", .{err});
        }
        m.datas.append(m.arena, .{
            .name = data_name,
            .content = content.items,
        }) catch |err| errExit("{t}", .{err});
    } else return false;
    return true;
}

fn addMethod(
    m: *Model,
    path: []const u8,
    lineno: u32,
    method_name: []const u8,
    flags: u16,
    synthetic: bool,
    sig_text: []const u8,
) void {
    const params_start: u16 = @intCast(m.params.items.len + 1);
    const sig, const trailing = parseMethodSig(m, path, lineno, sig_text, true);
    if (trailing.len > 0) errExit("{s}:{}: trailing '{s}'", .{ path, lineno, trailing });
    m.methods.append(m.arena, .{
        .owner = m.openTypeDef(),
        .name = dupe(m, method_name),
        .flags = flags,
        .sig = sig,
        .synthetic = synthetic,
        .params_start = params_start,
    }) catch |err| errExit("{t}", .{err});
    m.open_method = @intCast(m.methods.items.len - 1);
}

fn isTypeStart(token: []const u8) bool {
    if (std.mem.eql(u8, token, "class") or std.mem.eql(u8, token, "valuetype")) return true;
    var base = token;
    if (std.mem.endsWith(u8, base, "[]")) base = base[0 .. base.len - 2];
    for (elementary_types) |t| {
        if (std.mem.eql(u8, base, t[0])) return true;
    }
    return false;
}

// Normalizes '[instance] ( type [name] ... ) rettype' into space-separated tokens with the
// parameter names removed; when collect_params is given, each named parameter becomes a
// Param row with its 1-based position as the sequence. Returns the normalized signature
// and whatever text followed it.
fn parseMethodSig(
    m: *Model,
    path: []const u8,
    lineno: u32,
    text: []const u8,
    collect_params: bool,
) struct { []const u8, []const u8 } {
    var out: std.ArrayListUnmanaged(u8) = .{};
    var tokens: SigTokens = .{ .rest = text };
    const append = struct {
        fn append(model: *Model, list: *std.ArrayListUnmanaged(u8), token: []const u8) void {
            if (list.items.len > 0) list.append(model.arena, ' ') catch |err| errExit("{t}", .{err});
            list.appendSlice(model.arena, token) catch |err| errExit("{t}", .{err});
        }
    }.append;

    var token = tokens.next() orelse errExit("{s}:{}: missing signature", .{ path, lineno });
    if (std.mem.eql(u8, token, "instance")) {
        append(m, &out, token);
        token = tokens.next() orelse errExit("{s}:{}: missing signature", .{ path, lineno });
    }
    if (!std.mem.eql(u8, token, "(")) errExit("{s}:{}: expected '(' in signature", .{ path, lineno });
    append(m, &out, token);
    var seq: u16 = 0;
    while (true) {
        token = tokens.require();
        if (std.mem.eql(u8, token, ")")) break;
        seq += 1;
        append(m, &out, token);
        if (std.mem.eql(u8, token, "class") or std.mem.eql(u8, token, "valuetype")) {
            append(m, &out, tokens.require());
        }
        // a token that is not ')' and not a type is this parameter's name
        var peek = tokens;
        if (peek.next()) |next_token| {
            if (!std.mem.eql(u8, next_token, ")") and !isTypeStart(next_token)) {
                if (collect_params) {
                    m.params.append(m.arena, .{
                        .seq = seq,
                        .name = dupe(m, next_token),
                    }) catch |err| errExit("{t}", .{err});
                }
                tokens = peek;
            }
        }
    }
    append(m, &out, ")");
    token = tokens.require();
    append(m, &out, token);
    if (std.mem.eql(u8, token, "class") or std.mem.eql(u8, token, "valuetype")) {
        append(m, &out, tokens.require());
    }
    return .{ out.items, std.mem.trim(u8, tokens.rest, " \t") };
}

fn stripOpenBrace(path: []const u8, lineno: u32, rest: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, rest, "{")) errExit(
        "{s}:{}: expected the line to end with '{{'",
        .{ path, lineno },
    );
    return std.mem.trimRight(u8, rest[0 .. rest.len - 1], " \t");
}

fn joinLine(name: []const u8, rest: []const u8) []const u8 {
    // name and rest come from one contiguous line; rejoin them by pointer arithmetic
    if (rest.len == 0) return name;
    const start = name.ptr;
    const end = rest.ptr + rest.len;
    return start[0 .. @intFromPtr(end) - @intFromPtr(start)];
}

fn dupe(m: *Model, text: []const u8) []const u8 {
    return m.arena.dupe(u8, text) catch |err| errExit("{t}", .{err});
}

fn typedefFlag(path: []const u8, lineno: u32, arg: []const u8) u32 {
    const flags = [_]struct { []const u8, u32 }{
        .{ "public", 0x1 },
        .{ "nested-private", 0x3 },
        .{ "explicit-layout", 0x10 },
        .{ "sealed", 0x100 },
        .{ "beforefieldinit", 0x100000 },
    };
    for (flags) |f| {
        if (std.mem.eql(u8, arg, f[0])) return f[1];
    }
    errExit("{s}:{}: unknown typedef flag '{s}'", .{ path, lineno, arg });
}

fn fieldFlag(arg: []const u8) ?u16 {
    const flags = [_]struct { []const u8, u16 }{
        .{ "private", 0x1 },
        .{ "assembly", 0x3 },
        .{ "public", 0x6 },
        .{ "static", 0x10 },
        // literal and hasdefault; the '= value' on the field supplies the default
        .{ "const", 0x40 | 0x8000 },
        .{ "hasfieldrva", 0x100 },
    };
    for (flags) |f| {
        if (std.mem.eql(u8, arg, f[0])) return f[1];
    }
    return null;
}

fn methodFlag(path: []const u8, lineno: u32, arg: []const u8) u16 {
    const flags = [_]struct { []const u8, u16 }{
        .{ "private", 0x1 },
        .{ "public", 0x6 },
        .{ "static", 0x10 },
        .{ "hidebysig", 0x80 },
        .{ "specialname", 0x800 },
        .{ "rtspecialname", 0x1000 },
    };
    for (flags) |f| {
        if (std.mem.eql(u8, arg, f[0])) return f[1];
    }
    errExit("{s}:{}: unknown method flag '{s}'", .{ path, lineno, arg });
}

fn parseVersion(path: []const u8, lineno: u32, text: []const u8) [4]u16 {
    var result: [4]u16 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&result) |*part| {
        const p = it.next() orelse errExit("{s}:{}: bad version '{s}'", .{ path, lineno, text });
        part.* = std.fmt.parseInt(u16, p, 10) catch errExit(
            "{s}:{}: bad version '{s}'",
            .{ path, lineno, text },
        );
    }
    if (it.next() != null) errExit("{s}:{}: bad version '{s}'", .{ path, lineno, text });
    return result;
}

fn keytokenBytes(text: []const u8) [8]u8 {
    if (text.len != 16) errExit("keytoken must be 16 hex digits, got '{s}'", .{text});
    var bytes: [8]u8 = undefined;
    for (&bytes, 0..) |*b, i| {
        const hi = std.fmt.charToDigit(text[i * 2], 16) catch errExit("bad keytoken '{s}'", .{text});
        const lo = std.fmt.charToDigit(text[i * 2 + 1], 16) catch errExit("bad keytoken '{s}'", .{text});
        b.* = hi << 4 | lo;
    }
    return bytes;
}

// ---------------------------------------------------------------------------- emission

pub const Output = struct {
    bodies: []const u8,
    tables: []const u8,
    strings: []const u8,
    us: []const u8,
    blob: []const u8,
};

const Emit = struct {
    m: *Model,
    frozen: bool = false,
    strings: std.ArrayListUnmanaged(u8) = .{},
    string_entries: std.ArrayListUnmanaged(struct { offset: u32, len: u32 }) = .{},
    us: std.ArrayListUnmanaged(u8) = .{},
    us_entries: std.ArrayListUnmanaged(struct { text: []const u8, offset: u32 }) = .{},
    blob: std.ArrayListUnmanaged(u8) = .{},
    blob_entries: std.ArrayListUnmanaged(struct { offset: u32, len: u32 }) = .{},
    typeref_rows: std.ArrayListUnmanaged(u32) = .{},
    memberref_rows: std.ArrayListUnmanaged(u32) = .{},
    standalone_rows: std.ArrayListUnmanaged(u16) = .{},
    typedef_interned: []bool,
    method_rvas: []u32,
    data_rvas: std.ArrayListUnmanaged(struct { name: []const u8, rva: u32 }) = .{},

    fn arena(e: *Emit) std.mem.Allocator {
        return e.m.arena;
    }

    fn dataRva(e: *Emit, name: []const u8) ?u32 {
        for (e.data_rvas.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d.rva;
        }
        return null;
    }

    fn internString(e: *Emit, value: []const u8) u16 {
        if (value.len == 0) return 0;
        for (e.string_entries.items) |entry| {
            if (std.mem.eql(u8, e.strings.items[entry.offset..][0..entry.len], value))
                return @intCast(entry.offset);
        }
        if (e.frozen) errExit("'{s}' is not in the string heap", .{value});
        if (e.strings.items.len == 0) e.strings.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
        const offset: u32 = @intCast(e.strings.items.len);
        e.strings.appendSlice(e.arena(), value) catch |err| errExit("{t}", .{err});
        e.strings.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
        e.string_entries.append(e.arena(), .{
            .offset = offset,
            .len = @intCast(value.len),
        }) catch |err| errExit("{t}", .{err});
        return @intCast(offset);
    }

    fn internUs(e: *Emit, text: []const u8) u32 {
        for (e.us_entries.items) |entry| {
            if (std.mem.eql(u8, entry.text, text)) return entry.offset;
        }
        if (e.frozen) errExit("\"{s}\" is not in the user string heap", .{text});
        if (e.us.items.len == 0) e.us.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
        const offset: u32 = @intCast(e.us.items.len);
        // utf-16 length plus the trailing flag byte, as a compressed unsigned
        const byte_len = text.len * 2 + 1;
        if (byte_len > 0x7f) errExit("long user strings are not implemented", .{});
        e.us.append(e.arena(), @intCast(byte_len)) catch |err| errExit("{t}", .{err});
        var flag: u8 = 0;
        for (text) |c| {
            if (c >= 0x80) errExit("non-ascii user strings are not implemented", .{});
            e.us.append(e.arena(), c) catch |err| errExit("{t}", .{err});
            e.us.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
            const special = (c >= 0x01 and c <= 0x08) or (c >= 0x0e and c <= 0x1f) or
                c == 0x27 or c == 0x2d or c == 0x7f;
            if (special) flag = 1;
        }
        e.us.append(e.arena(), flag) catch |err| errExit("{t}", .{err});
        e.us_entries.append(e.arena(), .{
            .text = e.m.arena.dupe(u8, text) catch |err| errExit("{t}", .{err}),
            .offset = offset,
        }) catch |err| errExit("{t}", .{err});
        return offset;
    }

    fn internBlob(e: *Emit, content: []const u8) u16 {
        for (e.blob_entries.items) |entry| {
            if (std.mem.eql(u8, e.blob.items[entry.offset..][0..entry.len], content)) {
                return @intCast(entry.offset - 1);
            }
        }
        if (e.frozen) errExit("blob {x} is not in the blob heap", .{content});
        if (e.blob.items.len == 0) e.blob.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
        if (content.len > 0x7f) errExit("long blobs are not implemented", .{});
        const prefix_offset: u32 = @intCast(e.blob.items.len);
        e.blob.append(e.arena(), @intCast(content.len)) catch |err| errExit("{t}", .{err});
        e.blob.appendSlice(e.arena(), content) catch |err| errExit("{t}", .{err});
        e.blob_entries.append(e.arena(), .{
            .offset = prefix_offset + 1,
            .len = @intCast(content.len),
        }) catch |err| errExit("{t}", .{err});
        return @intCast(prefix_offset);
    }

    fn internMethodSig(e: *Emit, text: []const u8) u16 {
        var buf: [0x80]u8 = undefined;
        var w: BlobWriter = .{ .buf = &buf };
        encodeMethodSig(e, &w, text);
        return e.internBlob(buf[0..w.len]);
    }

    fn internFieldSig(e: *Emit, text: []const u8) u16 {
        var buf: [0x80]u8 = undefined;
        var w: BlobWriter = .{ .buf = &buf };
        var tokens: SigTokens = .{ .rest = text };
        w.byte(0x06);
        encodeType(e, &w, &tokens, tokens.require());
        return e.internBlob(buf[0..w.len]);
    }

    // 1-based index into the declared typedefs; the table row is this plus one, because
    // the <Module> typedef mdc synthesizes is row 1
    fn findTypeDef(e: *Emit, name: []const u8) ?u16 {
        for (e.m.typedefs.items, 1..) |t, i| {
            if (std.mem.eql(u8, t.name, name)) return @intCast(i);
        }
        return null;
    }

    fn typeDefRow(e: *Emit, name: []const u8) ?u16 {
        const declared = e.findTypeDef(name) orelse return null;
        const t = &e.m.typedefs.items[declared - 1];
        if (t.synthetic) e.internSyntheticTypeDef(declared);
        return declared + 1;
    }

    fn findOrCreateTypeRef(e: *Emit, name: []const u8) u16 {
        for (e.typeref_rows.items, 1..) |import_index, row| {
            if (std.mem.eql(u8, e.m.typerefs.items[import_index].name, name)) return @intCast(row);
        }
        if (e.frozen) errExit("typeref '{s}' has no row", .{name});
        const import_index: u32 = for (e.m.typerefs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, name)) break @intCast(i);
        } else errExit("'{s}' is not an imported typeref", .{name});
        const t = &e.m.typerefs.items[import_index];
        _ = e.internString(t.scope);
        _ = e.internString(t.ns);
        _ = e.internString(t.name);
        e.typeref_rows.append(e.arena(), import_index) catch |err| errExit("{t}", .{err});
        return @intCast(e.typeref_rows.items.len);
    }

    fn findOrCreateMemberRef(e: *Emit, class: []const u8, name: []const u8) u16 {
        for (e.memberref_rows.items, 1..) |import_index, row| {
            const member = &e.m.memberrefs.items[import_index];
            if (std.mem.eql(u8, member.class, class) and std.mem.eql(u8, member.name, name))
                return @intCast(row);
        }
        if (e.frozen) errExit("memberref '{s}::{s}' has no row", .{ class, name });
        const import_index: u32 = for (e.m.memberrefs.items, 0..) |member, i| {
            if (std.mem.eql(u8, member.class, class) and std.mem.eql(u8, member.name, name)) break @intCast(i);
        } else errExit("'{s}::{s}' is not an imported memberref", .{ class, name });
        const member = &e.m.memberrefs.items[import_index];
        _ = e.findOrCreateTypeRef(member.class);
        _ = e.internMethodSig(member.sig);
        _ = e.internString(member.name);
        e.memberref_rows.append(e.arena(), import_index) catch |err| errExit("{t}", .{err});
        return @intCast(e.memberref_rows.items.len);
    }

    fn findOrCreateStandaloneSig(e: *Emit, sig_offset: u16) u16 {
        for (e.standalone_rows.items, 1..) |offset, row| {
            if (offset == sig_offset) return @intCast(row);
        }
        if (e.frozen) errExit("standalone sig has no row", .{});
        e.standalone_rows.append(e.arena(), sig_offset) catch |err| errExit("{t}", .{err});
        return @intCast(e.standalone_rows.items.len);
    }

    // csc creates the array-initializer machinery mid-body, at the first instruction to
    // reference it; interning a synthetic typedef pulls in its extends, its custom
    // attributes and its fields, recursively
    fn internSyntheticTypeDef(e: *Emit, declared: u16) void {
        if (e.typedef_interned[declared - 1]) return;
        e.typedef_interned[declared - 1] = true;
        const t = &e.m.typedefs.items[declared - 1];
        if (t.extends.len > 0) _ = e.typeDefOrRef(t.extends);
        _ = e.internString(t.name);
        _ = e.internString(t.ns);
        for (e.m.custom_attributes.items) |ca| {
            if (!std.mem.eql(u8, ca.parent, t.name)) continue;
            const sep = std.mem.indexOf(u8, ca.ctor, "::") orelse errExit(
                "customattribute ctor '{s}' is not Class::Name",
                .{ca.ctor},
            );
            _ = e.findOrCreateMemberRef(ca.ctor[0..sep], ca.ctor[sep + 2 ..]);
            var buf: [0x80]u8 = undefined;
            _ = e.internBlob(encodeCaValue(ca.value, &buf));
        }
        for (e.m.fields.items) |f| {
            if (f.owner != declared) continue;
            _ = e.internFieldSig(f.sig);
            _ = e.internString(f.name);
        }
        for (e.m.methods.items) |method| {
            if (method.owner != declared) continue;
            _ = e.internMethodSig(method.sig);
            _ = e.internString(method.name);
        }
    }

    // TypeDefOrRef: 2 tag bits, 0 typedef, 1 typeref
    fn typeDefOrRef(e: *Emit, name: []const u8) u32 {
        if (e.typeDefRow(name)) |row| return @as(u32, row) << 2 | 0;
        return @as(u32, e.findOrCreateTypeRef(name)) << 2 | 1;
    }

    fn typeToken(e: *Emit, name: []const u8) u32 {
        if (e.typeDefRow(name)) |row| return 0x02000000 | @as(u32, row);
        return 0x01000000 | @as(u32, e.findOrCreateTypeRef(name));
    }

    fn findField(e: *Emit, qualified: []const u8) u16 {
        const sep = std.mem.indexOf(u8, qualified, "::") orelse errExit(
            "field reference '{s}' is not Class::Name",
            .{qualified},
        );
        const class = e.findTypeDef(qualified[0..sep]) orelse errExit(
            "'{s}' is not a typedef",
            .{qualified[0..sep]},
        );
        if (e.m.typedefs.items[class - 1].synthetic) e.internSyntheticTypeDef(class);
        const field_name = qualified[sep + 2 ..];
        for (e.m.fields.items, 1..) |f, i| {
            if (f.owner == class and std.mem.eql(u8, f.name, field_name)) return @intCast(i);
        }
        errExit("no field '{s}'", .{qualified});
    }

    fn methodTarget(e: *Emit, qualified: []const u8) struct { token: u32, sig: []const u8 } {
        const sep = std.mem.indexOf(u8, qualified, "::") orelse errExit(
            "method reference '{s}' is not Class::Name",
            .{qualified},
        );
        const class = qualified[0..sep];
        const method_name = qualified[sep + 2 ..];
        if (e.findTypeDef(class)) |def| {
            for (e.m.methods.items, 1..) |method, i| {
                if (method.owner == def and std.mem.eql(u8, method.name, method_name)) {
                    return .{ .token = 0x06000000 | @as(u32, @intCast(i)), .sig = method.sig };
                }
            }
            errExit("no method '{s}'", .{qualified});
        }
        const row = e.findOrCreateMemberRef(class, method_name);
        return .{
            .token = 0x0a000000 | @as(u32, row),
            .sig = e.m.memberrefs.items[e.memberref_rows.items[row - 1]].sig,
        };
    }
};

pub fn finish(m: *Model, bodies_rva: u32) Output {
    if (m.open_method != null or m.typedef_stack.items.len > 0) errExit("{s}: unclosed block at end of file", .{m.path});
    if (m.typedefs.items.len == 0) return .{ .bodies = "", .tables = "", .strings = "", .us = "", .blob = "" };
    const interned = m.arena.alloc(bool, m.typedefs.items.len) catch |err| errExit("{t}", .{err});
    @memset(interned, false);
    const method_rvas = m.arena.alloc(u32, m.methods.items.len) catch |err| errExit("{t}", .{err});
    var e: Emit = .{ .m = m, .typedef_interned = interned, .method_rvas = method_rvas };

    // 1: assemblyref key tokens
    for (m.assemblyrefs.items) |a| {
        _ = e.internBlob(&keytokenBytes(a.keytoken));
    }

    // 2: the module - the implicit <Module> typedef, then the module file name
    _ = e.internString("<Module>");
    _ = e.internString(m.module_name orelse errExit("no module", .{}));

    // 3: typedef names
    for (m.typedefs.items) |t| {
        if (t.synthetic) continue;
        _ = e.internString(t.name);
        _ = e.internString(t.ns);
    }

    // 4: base types
    for (m.typedefs.items) |t| {
        if (t.synthetic) continue;
        if (t.extends.len > 0) _ = e.typeDefOrRef(t.extends);
    }

    // 5: members, methods before fields, constants right after their field
    for (m.typedefs.items, 1..) |t, ti| {
        if (t.synthetic) continue;
        for (m.methods.items) |method| {
            if (method.owner != ti or method.synthetic) continue;
            _ = e.internMethodSig(method.sig);
            _ = e.internString(method.name);
        }
        for (m.fields.items) |f| {
            if (f.owner != ti) continue;
            _ = e.internFieldSig(f.sig);
            _ = e.internString(f.name);
            if (f.constant) |value| {
                var buf: [8]u8 = undefined;
                _ = e.internBlob(constantValue(f.sig, value, &buf).bytes);
            }
        }
    }

    // 6: parameter names
    for (m.params.items) |p| {
        _ = e.internString(p.name);
    }

    // 7: custom attribute constructors, except on synthetic types
    for (m.custom_attributes.items) |ca| {
        if (e.findTypeDef(ca.parent)) |i| {
            if (m.typedefs.items[i - 1].synthetic) continue;
        }
        const sep = std.mem.indexOf(u8, ca.ctor, "::") orelse errExit(
            "customattribute ctor '{s}' is not Class::Name",
            .{ca.ctor},
        );
        _ = e.findOrCreateMemberRef(ca.ctor[0..sep], ca.ctor[sep + 2 ..]);
    }

    // 8: bodies, interning whatever their instructions touch, locals last per body;
    // synthetic methods intern their name and signature when their body is reached
    const bodies = emitBodies(&e, bodies_rva);

    // 9: custom attribute values, except on synthetic types which interned during 8
    for (m.custom_attributes.items) |ca| {
        if (e.findTypeDef(ca.parent)) |i| {
            if (m.typedefs.items[i - 1].synthetic) continue;
        }
        var buf: [0x80]u8 = undefined;
        _ = e.internBlob(encodeCaValue(ca.value, &buf));
    }

    // 10: whatever remains referenced only from rows
    if (m.assembly) |a| _ = e.internString(a.name);
    for (m.assemblyrefs.items) |a| _ = e.internString(a.name);

    e.frozen = true;
    const tables = emitTables(&e);
    return .{
        .bodies = bodies,
        .tables = tables,
        .strings = e.strings.items,
        .us = e.us.items,
        .blob = e.blob.items,
    };
}

const ConstantValue = struct { type_byte: u8, bytes: []const u8 };

// the constant's type is the field's own type
fn constantValue(field_type: []const u8, value: []const u8, buf: *[8]u8) ConstantValue {
    if (std.mem.eql(u8, field_type, "i4")) {
        std.mem.writeInt(i32, buf[0..4], parseIntPlain(i32, value), .little);
        return .{ .type_byte = 0x08, .bytes = buf[0..4] };
    }
    if (std.mem.eql(u8, field_type, "r4")) {
        std.mem.writeInt(u32, buf[0..4], @bitCast(parseFloat(f32, value)), .little);
        return .{ .type_byte = 0x0c, .bytes = buf[0..4] };
    }
    errExit("constants of type '{s}' are not implemented", .{field_type});
}

// ---------------------------------------------------------------------------- signatures

const SigTokens = struct {
    rest: []const u8,

    fn next(t: *SigTokens) ?[]const u8 {
        t.rest = std.mem.trimLeft(u8, t.rest, " \t");
        if (t.rest.len == 0) return null;
        if (t.rest[0] == '(' or t.rest[0] == ')') {
            const tok = t.rest[0..1];
            t.rest = t.rest[1..];
            return tok;
        }
        var end: usize = 0;
        while (end < t.rest.len and t.rest[end] != ' ' and t.rest[end] != '\t' and
            t.rest[end] != '(' and t.rest[end] != ')') end += 1;
        const tok = t.rest[0..end];
        t.rest = t.rest[end..];
        return tok;
    }

    fn require(t: *SigTokens) []const u8 {
        return t.next() orelse errExit("truncated signature", .{});
    }
};

const elementary_types = [_]struct { []const u8, u8 }{
    .{ "void", 0x01 },
    .{ "bool", 0x02 },
    .{ "char", 0x03 },
    .{ "i1", 0x04 },
    .{ "u1", 0x05 },
    .{ "i2", 0x06 },
    .{ "u2", 0x07 },
    .{ "i4", 0x08 },
    .{ "u4", 0x09 },
    .{ "i8", 0x0a },
    .{ "u8", 0x0b },
    .{ "r4", 0x0c },
    .{ "r8", 0x0d },
    .{ "string", 0x0e },
    .{ "object", 0x1c },
};

const BlobWriter = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(w: *BlobWriter, b: u8) void {
        if (w.len == w.buf.len) errExit("blob too long", .{});
        w.buf[w.len] = b;
        w.len += 1;
    }

    fn compressed(w: *BlobWriter, value: u32) void {
        if (value > 0x7f) errExit("compressed values over 0x7f are not implemented", .{});
        w.byte(@intCast(value));
    }
};

fn encodeType(e: *Emit, w: *BlobWriter, tokens: *SigTokens, first: []const u8) void {
    var token = first;
    if (std.mem.eql(u8, token, "class")) {
        w.byte(0x12);
        w.compressed(e.typeDefOrRef(tokens.require()));
        return;
    }
    if (std.mem.eql(u8, token, "valuetype")) {
        w.byte(0x11);
        w.compressed(e.typeDefOrRef(tokens.require()));
        return;
    }
    if (std.mem.endsWith(u8, token, "[]")) {
        w.byte(0x1d);
        token = token[0 .. token.len - 2];
    }
    for (elementary_types) |t| {
        if (std.mem.eql(u8, token, t[0])) {
            w.byte(t[1]);
            return;
        }
    }
    errExit("unknown type '{s}'", .{token});
}

fn encodeMethodSig(e: *Emit, w: *BlobWriter, text: []const u8) void {
    var tokens: SigTokens = .{ .rest = text };
    var callconv_byte: u8 = 0;
    var token = tokens.require();
    if (std.mem.eql(u8, token, "instance")) {
        callconv_byte = 0x20;
        token = tokens.require();
    }
    if (!std.mem.eql(u8, token, "(")) errExit("expected '(' in method sig", .{});
    w.byte(callconv_byte);
    const count_at = w.len;
    w.byte(0);
    var count: u8 = 0;
    while (true) {
        const t = tokens.require();
        if (std.mem.eql(u8, t, ")")) break;
        encodeType(e, w, &tokens, t);
        count += 1;
    }
    // ECMA order is callconv, count, return type, then params - move the return
    // type in front of the params just written
    const ret_start = w.len;
    encodeType(e, w, &tokens, tokens.require());
    const ret_len = w.len - ret_start;
    var tmp: [8]u8 = undefined;
    if (ret_len > tmp.len) errExit("return type too long", .{});
    @memcpy(tmp[0..ret_len], w.buf[ret_start..w.len]);
    std.mem.copyBackwards(u8, w.buf[count_at + 1 + ret_len .. w.len], w.buf[count_at + 1 .. ret_start]);
    @memcpy(w.buf[count_at + 1 ..][0..ret_len], tmp[0..ret_len]);
    w.buf[count_at] = count;
}

fn encodeCaValue(text: []const u8, buf: []u8) []const u8 {
    var w: BlobWriter = .{ .buf = buf };
    var tokens: SigTokens = .{ .rest = text };
    const kind = tokens.require();
    if (!std.mem.eql(u8, kind, "ca")) errExit("expected 'ca', got '{s}'", .{kind});
    w.byte(1);
    w.byte(0);
    var named_count: u16 = 0;
    var named_at: ?usize = null;
    while (tokens.next()) |t| {
        if (std.mem.eql(u8, t, "i4")) {
            if (named_at != null) errExit("fixed ca argument after named", .{});
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, parseIntPlain(i32, tokens.require()), .little);
            for (b) |x| w.byte(x);
        } else if (std.mem.eql(u8, t, "property")) {
            if (named_at == null) {
                named_at = w.len;
                w.byte(0);
                w.byte(0);
            }
            named_count += 1;
            const type_name = tokens.require();
            if (!std.mem.eql(u8, type_name, "bool")) errExit("only bool ca properties", .{});
            const prop_name = tokens.require();
            const value = tokens.require();
            w.byte(0x54);
            w.byte(0x02);
            w.compressed(@intCast(prop_name.len));
            for (prop_name) |c| w.byte(c);
            w.byte(if (std.mem.eql(u8, value, "true")) 1 else 0);
        } else errExit("unknown ca argument '{s}'", .{t});
    }
    if (named_at) |at| {
        std.mem.writeInt(u16, w.buf[at..][0..2], named_count, .little);
    } else {
        w.byte(0);
        w.byte(0);
    }
    return buf[0..w.len];
}

// ---------------------------------------------------------------------------- bodies

const Opcode = struct {
    name: []const u8,
    code: u8,
    operand: enum { none, i1, i4, i8, r4, r8, branch1, method, field, type, ustring },
    // stack effect; call and newobj take theirs from the target's signature instead
    pops: u16 = 0,
    pushes: u16 = 0,
};

const opcodes = [_]Opcode{
    .{ .name = "nop", .code = 0x00, .operand = .none },
    .{ .name = "ldarg.0", .code = 0x02, .operand = .none, .pushes = 1 },
    .{ .name = "ldarg.1", .code = 0x03, .operand = .none, .pushes = 1 },
    .{ .name = "ldloc.0", .code = 0x06, .operand = .none, .pushes = 1 },
    .{ .name = "stloc.0", .code = 0x0a, .operand = .none, .pops = 1 },
    .{ .name = "ldnull", .code = 0x14, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.m1", .code = 0x15, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.0", .code = 0x16, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.1", .code = 0x17, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.2", .code = 0x18, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.3", .code = 0x19, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.4", .code = 0x1a, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.5", .code = 0x1b, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.6", .code = 0x1c, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.7", .code = 0x1d, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.8", .code = 0x1e, .operand = .none, .pushes = 1 },
    .{ .name = "ldc.i4.s", .code = 0x1f, .operand = .i1, .pushes = 1 },
    .{ .name = "ldc.i4", .code = 0x20, .operand = .i4, .pushes = 1 },
    .{ .name = "ldc.i8", .code = 0x21, .operand = .i8, .pushes = 1 },
    .{ .name = "ldc.r4", .code = 0x22, .operand = .r4, .pushes = 1 },
    .{ .name = "ldc.r8", .code = 0x23, .operand = .r8, .pushes = 1 },
    .{ .name = "dup", .code = 0x25, .operand = .none, .pops = 1, .pushes = 2 },
    .{ .name = "call", .code = 0x28, .operand = .method },
    .{ .name = "ret", .code = 0x2a, .operand = .none },
    .{ .name = "br.s", .code = 0x2b, .operand = .branch1 },
    .{ .name = "conv.i8", .code = 0x6a, .operand = .none, .pops = 1, .pushes = 1 },
    .{ .name = "ldstr", .code = 0x72, .operand = .ustring, .pushes = 1 },
    .{ .name = "newobj", .code = 0x73, .operand = .method },
    .{ .name = "stfld", .code = 0x7d, .operand = .field, .pops = 2 },
    .{ .name = "stsfld", .code = 0x80, .operand = .field, .pops = 1 },
    .{ .name = "newarr", .code = 0x8d, .operand = .type, .pops = 1, .pushes = 1 },
    .{ .name = "stelem.ref", .code = 0xa2, .operand = .none, .pops = 3 },
    .{ .name = "ldtoken", .code = 0xd0, .operand = .field, .pushes = 1 },
};

// how many values a method signature pops and whether it pushes one back
const SigStackEffect = struct { pops: u16, pushes: u16 };

// HasCustomAttribute: 5 tag bits, 3 = typedef, 14 = assembly
fn caParent(e: *Emit, ca: *const Model.CustomAttribute) u32 {
    if (std.mem.eql(u8, ca.parent, "assembly")) return 1 << 5 | 14;
    const row = e.typeDefRow(ca.parent) orelse errExit(
        "unknown customattribute parent '{s}'",
        .{ca.parent},
    );
    return @as(u32, row) << 5 | 3;
}

fn sigStackEffect(sig: []const u8) SigStackEffect {
    var tokens: SigTokens = .{ .rest = sig };
    var pops: u16 = 0;
    var token = tokens.require();
    if (std.mem.eql(u8, token, "instance")) {
        pops += 1;
        token = tokens.require();
    }
    while (true) {
        token = tokens.require();
        if (std.mem.eql(u8, token, ")")) break;
        if (std.mem.eql(u8, token, "(")) continue;
        if (std.mem.eql(u8, token, "class") or std.mem.eql(u8, token, "valuetype")) {
            _ = tokens.require();
        }
        pops += 1;
    }
    const ret = tokens.require();
    return .{ .pops = pops, .pushes = if (std.mem.eql(u8, ret, "void")) 0 else 1 };
}

const max_labels = 16;

const Labels = struct {
    defined: [max_labels]struct { name: []const u8, offset: u32 } = undefined,
    defined_count: usize = 0,
    // each branch records where its offset byte lives and where it branches from
    fixups: [max_labels]struct { name: []const u8, at: u32, base: u32 } = undefined,
    fixup_count: usize = 0,

    fn apply(labels: *const Labels, body_name: []const u8, code: []u8) void {
        for (labels.fixups[0..labels.fixup_count]) |fixup| {
            const target = for (labels.defined[0..labels.defined_count]) |label| {
                if (std.mem.eql(u8, label.name, fixup.name)) break label.offset;
            } else errExit("body '{s}': no label '{s}'", .{ body_name, fixup.name });
            const delta = @as(i64, target) - fixup.base;
            if (delta < -128 or delta > 127) errExit(
                "body '{s}': label '{s}' is out of short branch range",
                .{ body_name, fixup.name },
            );
            code[fixup.at] = @bitCast(@as(i8, @intCast(delta)));
        }
    }
};

fn assembleBody(e: *Emit, body: *const Model.Method, code: *std.ArrayListUnmanaged(u8)) u16 {
    var depth: u16 = 0;
    var maxstack: u16 = 0;
    var labels: Labels = .{};
    for (body.instructions.items) |line| {
        var it = line;
        const mnemonic = nextArg(&it) orelse continue;
        if (mnemonic[mnemonic.len - 1] == ':' and it.len == 0) {
            const label_name = mnemonic[0 .. mnemonic.len - 1];
            for (labels.defined[0..labels.defined_count]) |label| {
                if (std.mem.eql(u8, label.name, label_name)) errExit(
                    "body '{s}': second label '{s}'",
                    .{ body.name, label_name },
                );
            }
            if (labels.defined_count == max_labels) errExit("too many labels", .{});
            labels.defined[labels.defined_count] = .{
                .name = label_name,
                .offset = @intCast(code.items.len),
            };
            labels.defined_count += 1;
            continue;
        }
        const op = for (&opcodes) |*op| {
            if (std.mem.eql(u8, op.name, mnemonic)) break op;
        } else errExit("unknown instruction '{s}'", .{mnemonic});
        code.append(e.arena(), op.code) catch |err| errExit("{t}", .{err});
        const operand = std.mem.trim(u8, it, " \t");
        var buf: [8]u8 = undefined;
        var pops: u16 = op.pops;
        var pushes: u16 = op.pushes;
        const bytes: []const u8 = switch (op.operand) {
            .none => "",
            .i1 => blk: {
                buf[0] = @bitCast(parseIntPlain(i8, operand));
                break :blk buf[0..1];
            },
            .branch1 => blk: {
                if (labels.fixup_count == max_labels) errExit("too many branches", .{});
                labels.fixups[labels.fixup_count] = .{
                    .name = operand,
                    .at = @intCast(code.items.len),
                    .base = @intCast(code.items.len + 1),
                };
                labels.fixup_count += 1;
                buf[0] = 0;
                break :blk buf[0..1];
            },
            .i4 => blk: {
                std.mem.writeInt(i32, buf[0..4], parseIntPlain(i32, operand), .little);
                break :blk buf[0..4];
            },
            .i8 => blk: {
                std.mem.writeInt(i64, buf[0..8], parseIntPlain(i64, operand), .little);
                break :blk buf[0..8];
            },
            .r4 => blk: {
                std.mem.writeInt(u32, buf[0..4], @bitCast(parseFloat(f32, operand)), .little);
                break :blk buf[0..4];
            },
            .r8 => blk: {
                std.mem.writeInt(u64, buf[0..8], @bitCast(parseFloat(f64, operand)), .little);
                break :blk buf[0..8];
            },
            .method => blk: {
                const target = e.methodTarget(operand);
                const effect = sigStackEffect(target.sig);
                if (op.code == 0x73) {
                    // newobj creates the instance the signature would pop, and pushes it
                    pops = effect.pops - 1;
                    pushes = 1;
                } else {
                    pops = effect.pops;
                    pushes = effect.pushes;
                }
                std.mem.writeInt(u32, buf[0..4], target.token, .little);
                break :blk buf[0..4];
            },
            .field => blk: {
                std.mem.writeInt(u32, buf[0..4], 0x04000000 | @as(u32, e.findField(operand)), .little);
                break :blk buf[0..4];
            },
            .type => blk: {
                std.mem.writeInt(u32, buf[0..4], e.typeToken(operand), .little);
                break :blk buf[0..4];
            },
            .ustring => blk: {
                if (operand.len < 2 or operand[0] != '"' or operand[operand.len - 1] != '"')
                    errExit("ldstr needs a quoted string, got '{s}'", .{operand});
                std.mem.writeInt(u32, buf[0..4], 0x70000000 | e.internUs(operand[1 .. operand.len - 1]), .little);
                break :blk buf[0..4];
            },
        };
        code.appendSlice(e.arena(), bytes) catch |err| errExit("{t}", .{err});
        if (pops > depth) errExit(
            "body '{s}': '{s}' pops {} with {} on the stack",
            .{ body.name, line, pops, depth },
        );
        depth = depth - pops + pushes;
        if (depth > maxstack) maxstack = depth;
    }
    labels.apply(body.name, code.items);
    return maxstack;
}

fn localSigToken(e: *Emit, locals: []const u8) u32 {
    // a body's locals are a sig without the leading 'locals' keyword
    var buf: [0x80]u8 = undefined;
    var w: BlobWriter = .{ .buf = &buf };
    var tokens: SigTokens = .{ .rest = locals };
    w.byte(0x07);
    const count_at = w.len;
    w.byte(0);
    var count: u8 = 0;
    while (tokens.next()) |t| {
        encodeType(e, &w, &tokens, t);
        count += 1;
    }
    w.buf[count_at] = count;
    const sig_offset = e.internBlob(buf[0..w.len]);
    return 0x11000000 | @as(u32, e.findOrCreateStandaloneSig(sig_offset));
}

fn emitBodies(e: *Emit, bodies_rva: u32) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    // bodies land per class, in declaration order within the class except that the
    // .cctor comes before the .ctor - the reverse of their row order
    for (e.m.typedefs.items, 1..) |_, ti| {
        for (0..3) |pass| {
            for (e.m.methods.items, 0..) |*method, mi| {
                if (method.owner != ti) continue;
                const is_ctor = std.mem.eql(u8, method.name, ".ctor");
                const is_cctor = std.mem.eql(u8, method.name, ".cctor");
                const wanted: usize = if (is_cctor) 1 else if (is_ctor) 2 else 0;
                if (wanted != pass) continue;
                emitOneBody(e, bodies_rva, &out, method, mi);
            }
        }
    }
    while (out.items.len % 4 != 0) out.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
    return out.items;
}

fn emitOneBody(
    e: *Emit,
    bodies_rva: u32,
    out: *std.ArrayListUnmanaged(u8),
    method: *const Model.Method,
    method_index: usize,
) void {
    // an array initializer's data lands right before the first body whose ldtoken
    // references its field
    for (method.instructions.items) |line| {
        if (!std.mem.startsWith(u8, line, "ldtoken ")) continue;
        const operand = std.mem.trim(u8, line["ldtoken ".len..], " \t");
        const data_name = for (e.m.field_rvas.items) |f| {
            if (std.mem.eql(u8, f.field, operand)) break f.data;
        } else continue;
        if (e.dataRva(data_name) != null) continue;
        const data = for (e.m.datas.items) |*d| {
            if (std.mem.eql(u8, d.name, data_name)) break d;
        } else errExit("no data '{s}'", .{data_name});
        while ((bodies_rva + out.items.len) % 8 != 0)
            out.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
        e.data_rvas.append(e.arena(), .{
            .name = data.name,
            .rva = @intCast(bodies_rva + out.items.len),
        }) catch |err| errExit("{t}", .{err});
        out.appendSlice(e.arena(), data.content) catch |err| errExit("{t}", .{err});
    }

    if (method.synthetic) {
        _ = e.internString(method.name);
        _ = e.internMethodSig(method.sig);
    }
    var code: std.ArrayListUnmanaged(u8) = .{};
    const maxstack = assembleBody(e, method, &code);
    const fat = method.locals != null or code.items.len >= 64 or maxstack > 8;
    if (fat) {
        while ((bodies_rva + out.items.len) % 4 != 0)
            out.append(e.arena(), 0) catch |err| errExit("{t}", .{err});
    }
    e.method_rvas[method_index] = @intCast(bodies_rva + out.items.len);
    if (fat) {
        const flags: u16 = if (method.locals != null) 0x3013 else 0x3003;
        var header: [12]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], flags, .little);
        std.mem.writeInt(u16, header[2..4], maxstack, .little);
        std.mem.writeInt(u32, header[4..8], @intCast(code.items.len), .little);
        std.mem.writeInt(u32, header[8..12], if (method.locals) |l| localSigToken(e, l) else 0, .little);
        out.appendSlice(e.arena(), &header) catch |err| errExit("{t}", .{err});
    } else {
        out.append(e.arena(), @intCast(code.items.len << 2 | 0x2)) catch |err| errExit("{t}", .{err});
    }
    out.appendSlice(e.arena(), code.items) catch |err| errExit("{t}", .{err});
}

// ---------------------------------------------------------------------------- tables

const table_module = 0;
const table_typeref = 1;
const table_typedef = 2;
const table_field = 4;
const table_methoddef = 6;
const table_param = 8;
const table_memberref = 10;
const table_constant = 11;
const table_customattribute = 12;
const table_classlayout = 15;
const table_standalonesig = 17;
const table_fieldrva = 29;
const table_assembly = 32;
const table_assemblyref = 35;
const table_nestedclass = 41;

// which tables an ECMA-335 writer keeps sorted; csc writes this constant for any input
const sorted_tables_mask: u64 = 0x000016003325fa00;

fn emitTables(e: *Emit) []const u8 {
    var out = std.Io.Writer.Allocating.init(e.arena());
    emitTablesInner(e, e.m, &out.writer) catch |err| errExit("{t}", .{err});
    return out.written();
}

fn emitTablesInner(e: *Emit, m: *Model, w: *std.Io.Writer) error{ WriteFailed, OutOfMemory }!void {
    const counts = [_]struct { u32, u32 }{
        .{ table_module, 1 },
        .{ table_typeref, @intCast(e.typeref_rows.items.len) },
        .{ table_typedef, @intCast(m.typedefs.items.len + 1) },
        .{ table_field, @intCast(m.fields.items.len) },
        .{ table_methoddef, @intCast(m.methods.items.len) },
        .{ table_param, @intCast(m.params.items.len) },
        .{ table_memberref, @intCast(e.memberref_rows.items.len) },
        .{ table_constant, blk: {
            var n: u32 = 0;
            for (m.fields.items) |f| {
                if (f.constant != null) n += 1;
            }
            break :blk n;
        } },
        .{ table_customattribute, @intCast(m.custom_attributes.items.len) },
        .{ table_classlayout, @intCast(m.class_layouts.items.len) },
        .{ table_standalonesig, @intCast(e.standalone_rows.items.len) },
        .{ table_fieldrva, @intCast(m.field_rvas.items.len) },
        .{ table_assembly, if (m.assembly != null) @as(u32, 1) else 0 },
        .{ table_assemblyref, @intCast(m.assemblyrefs.items.len) },
        .{ table_nestedclass, @intCast(m.nested_classes.items.len) },
    };
    var valid: u64 = 0;
    for (counts) |c| {
        if (c[1] > 0) valid |= @as(u64, 1) << @intCast(c[0]);
    }

    try w.writeInt(u32, 0, .little); // reserved
    try w.writeInt(u8, 2, .little); // major version
    try w.writeInt(u8, 0, .little); // minor version
    try w.writeInt(u8, 0, .little); // heap sizes: all small
    try w.writeInt(u8, 1, .little); // reserved
    try w.writeInt(u64, valid, .little);
    try w.writeInt(u64, sorted_tables_mask, .little);
    for (counts) |c| {
        if (c[1] > 0) try w.writeInt(u32, c[1], .little);
    }

    // module
    try w.writeInt(u16, 0, .little); // generation
    try w.writeInt(u16, e.internString(m.module_name.?), .little);
    try w.writeInt(u16, 1, .little); // mvid
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);

    for (e.typeref_rows.items) |import_index| {
        const t = &m.typerefs.items[import_index];
        const scope = for (m.assemblyrefs.items, 1..) |a, i| {
            if (std.mem.eql(u8, a.name, t.scope)) break @as(u32, @intCast(i)) << 2 | 2;
        } else errExit("typeref scope '{s}' is not an assemblyref", .{t.scope});
        try w.writeInt(u16, @intCast(scope), .little);
        try w.writeInt(u16, e.internString(t.name), .little);
        try w.writeInt(u16, e.internString(t.ns), .little);
    }

    // the implicit <Module> typedef
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u16, e.internString("<Module>"), .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 1, .little);
    for (m.typedefs.items) |t| {
        try w.writeInt(u32, t.flags, .little);
        try w.writeInt(u16, e.internString(t.name), .little);
        try w.writeInt(u16, e.internString(t.ns), .little);
        try w.writeInt(u16, if (t.extends.len == 0) 0 else @intCast(e.typeDefOrRef(t.extends)), .little);
        try w.writeInt(u16, t.fields_start, .little);
        try w.writeInt(u16, t.methods_start, .little);
    }

    for (m.fields.items) |f| {
        try w.writeInt(u16, f.flags, .little);
        try w.writeInt(u16, e.internString(f.name), .little);
        try w.writeInt(u16, e.internFieldSig(f.sig), .little);
    }

    for (m.methods.items, 0..) |method, i| {
        try w.writeInt(u32, e.method_rvas[i], .little);
        try w.writeInt(u16, 0, .little); // implflags
        try w.writeInt(u16, method.flags, .little);
        try w.writeInt(u16, e.internString(method.name), .little);
        try w.writeInt(u16, e.internMethodSig(method.sig), .little);
        try w.writeInt(u16, method.params_start, .little);
    }

    for (m.params.items) |p| {
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, p.seq, .little);
        try w.writeInt(u16, e.internString(p.name), .little);
    }

    for (e.memberref_rows.items) |import_index| {
        const member = &m.memberrefs.items[import_index];
        const class = e.findOrCreateTypeRef(member.class);
        try w.writeInt(u16, @intCast(@as(u32, class) << 3 | 1), .little);
        try w.writeInt(u16, e.internString(member.name), .little);
        try w.writeInt(u16, e.internMethodSig(member.sig), .little);
    }

    for (m.fields.items, 1..) |f, fi| {
        const constant = f.constant orelse continue;
        var buf: [8]u8 = undefined;
        const value = constantValue(f.sig, constant, &buf);
        try w.writeInt(u8, value.type_byte, .little);
        try w.writeInt(u8, 0, .little); // padding
        // HasConstant: 2 tag bits, 0 = field
        try w.writeInt(u16, @intCast(@as(u32, @intCast(fi)) << 2 | 0), .little);
        try w.writeInt(u16, e.internBlob(value.bytes), .little);
    }

    // the CustomAttribute table is sorted by coded parent
    var ca_order: [64]u16 = undefined;
    if (m.custom_attributes.items.len > ca_order.len) errExit("too many custom attributes", .{});
    for (m.custom_attributes.items, 0..) |_, i| ca_order[i] = @intCast(i);
    std.mem.sort(u16, ca_order[0..m.custom_attributes.items.len], e, struct {
        fn lessThan(ctx: *Emit, a: u16, b: u16) bool {
            return caParent(ctx, &ctx.m.custom_attributes.items[a]) <
                caParent(ctx, &ctx.m.custom_attributes.items[b]);
        }
    }.lessThan);
    for (ca_order[0..m.custom_attributes.items.len]) |i| {
        const ca = &m.custom_attributes.items[i];
        const sep = std.mem.indexOf(u8, ca.ctor, "::") orelse errExit(
            "customattribute ctor '{s}' is not Class::Name",
            .{ca.ctor},
        );
        // CustomAttributeType: 3 tag bits, 3 = memberref
        const ctor = @as(u32, e.findOrCreateMemberRef(ca.ctor[0..sep], ca.ctor[sep + 2 ..])) << 3 | 3;
        var buf: [0x80]u8 = undefined;
        const value = encodeCaValue(ca.value, &buf);
        try w.writeInt(u16, @intCast(caParent(e, ca)), .little);
        try w.writeInt(u16, @intCast(ctor), .little);
        try w.writeInt(u16, e.internBlob(value), .little);
    }

    for (m.class_layouts.items) |c| {
        try w.writeInt(u16, c.packing, .little);
        try w.writeInt(u32, c.size, .little);
        try w.writeInt(u16, e.typeDefRow(c.parent) orelse errExit(
            "classlayout parent '{s}' is not a typedef",
            .{c.parent},
        ), .little);
    }

    for (e.standalone_rows.items) |sig_offset| {
        try w.writeInt(u16, sig_offset, .little);
    }

    for (m.field_rvas.items) |f| {
        try w.writeInt(u32, e.dataRva(f.data) orelse errExit("no data '{s}'", .{f.data}), .little);
        try w.writeInt(u16, e.findField(f.field), .little);
    }

    if (m.assembly) |a| {
        try w.writeInt(u32, 0x8004, .little); // hash algorithm, sha1
        for (a.version) |part| try w.writeInt(u16, part, .little);
        try w.writeInt(u32, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // public key
        try w.writeInt(u16, e.internString(a.name), .little);
        try w.writeInt(u16, 0, .little); // culture
    }

    for (m.assemblyrefs.items) |a| {
        for (a.version) |part| try w.writeInt(u16, part, .little);
        try w.writeInt(u32, 0, .little); // flags
        try w.writeInt(u16, e.internBlob(&keytokenBytes(a.keytoken)), .little);
        try w.writeInt(u16, e.internString(a.name), .little);
        try w.writeInt(u16, 0, .little); // culture
        try w.writeInt(u16, 0, .little); // hash value
    }

    for (m.nested_classes.items) |n| {
        try w.writeInt(u16, n.nested + 1, .little);
        try w.writeInt(u16, n.enclosing + 1, .little);
    }
}

// ---------------------------------------------------------------------------- shared helpers

fn nextArg(rest: *[]const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    const end = std.mem.indexOfAny(u8, rest.*, " \t") orelse rest.len;
    const a = rest.*[0..end];
    rest.* = std.mem.trimLeft(u8, rest.*[end..], " \t");
    if (a.len == 0) return null;
    return a;
}

fn requireArg(path: []const u8, lineno: u32, rest: *[]const u8) []const u8 {
    return nextArg(rest) orelse errExit("{s}:{}: missing argument", .{ path, lineno });
}

fn parseQuoted(path: []const u8, lineno: u32, text: []const u8) []const u8 {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') errExit(
        "{s}:{}: expected a quoted string, got '{s}'",
        .{ path, lineno, text },
    );
    return text[1 .. text.len - 1];
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
        return text[1 .. text.len - 1];
    return text;
}

fn parseInt(comptime T: type, path: []const u8, lineno: u32, text: []const u8) T {
    return std.fmt.parseInt(T, text, 0) catch |err| errExit(
        "{s}:{}: '{s}' is not a number ({t})",
        .{ path, lineno, text, err },
    );
}

fn parseIntPlain(comptime T: type, text: []const u8) T {
    return std.fmt.parseInt(T, text, 0) catch |err| errExit(
        "'{s}' is not a number ({t})",
        .{ text, err },
    );
}

fn parseFloat(comptime T: type, text: []const u8) T {
    return std.fmt.parseFloat(T, text) catch |err| errExit(
        "'{s}' is not a float ({t})",
        .{ text, err },
    );
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
