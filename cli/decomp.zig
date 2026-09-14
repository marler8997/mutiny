pub fn go(arena: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
    const name = args.next() orelse errExit("decomp requires a game name, as shown by mutiny scan or the GUI", .{});
    if (std.mem.indexOfAny(u8, name, "\\/:") != null) errExit("'{s}' looks like a path, pass the game's name", .{name});
    if (args.next()) |extra| errExit("unexpected argument '{s}' after the game name", .{extra});

    var app_path_buf: [max_app_path]u8 = undefined;
    const app = openAppDir(name, &app_path_buf);
    var exe_buf: [appdata.max_exepath]u8 = undefined;
    const exe = app.dir.readFile("exepath", &exe_buf) catch |err| switch (err) {
        error.FileNotFound => errExit("'{s}' has never been attached to, so its exe is not known", .{name}),
        else => errExit("read '{s}\\exepath' failed with {t}", .{ app.path, err }),
    };

    var input_bufs: InputBufs = undefined;
    const inputs = Inputs.fromExe(exe, &input_bufs) catch return error.Reported;
    app.dir.makePath("decomp") catch |err| errExit("create '{s}\\decomp' failed with {t}", .{ app.path, err });
    const out = app.dir.openDir("decomp", .{ .iterate = true }) catch |err| errExit(
        "open '{s}\\decomp' failed with {t}",
        .{ app.path, err },
    );

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const totals = run(arena, inputs, out, &stdout_writer) catch return error.Reported;

    if (totals.updated == 0 and totals.failed == 0) {
        stdout.writeAll("  everything is already up to date, nothing written\n") catch return stdout_writer.err.?;
    } else if (totals.unchanged != 0) {
        stdout.print("  {d} other assemblies unchanged\n", .{totals.unchanged}) catch return stdout_writer.err.?;
    }
    stdout.print("  {d} assemblies, {d} types\n", .{ totals.assemblies, totals.types }) catch return stdout_writer.err.?;
    stdout.flush() catch return stdout_writer.err.?;
    return if (totals.failed == 0) 0 else 0xff;
}

// LOCALAPPDATA as WTF-8, then \mutiny\app\<Name>, where <Name> is an exe's base name and so a
// single path component
const max_app_path = appdata.max_path * 3 + "\\mutiny\\app\\".len + std.fs.max_name_bytes;

const AppDir = struct {
    dir: std.fs.Dir,
    path: []const u8,
};

fn openAppDir(name: []const u8, buf: *[max_app_path]u8) AppDir {
    const localappdata_w = appdata.get() orelse errExit("no LOCALAPPDATA environment variable", .{});
    var localappdata_buf: [appdata.max_path * 3]u8 = undefined;
    const localappdata = localappdata_buf[0..std.unicode.wtf16LeToWtf8(&localappdata_buf, localappdata_w)];
    const path = std.fmt.bufPrint(buf, "{s}\\mutiny\\app\\{s}", .{ localappdata, name }) catch |err| switch (err) {
        error.NoSpaceLeft => errExit("'{s}' is too long for a game name", .{name}),
    };
    const dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => errExit("'{s}' is not a game Mutiny knows (no '{s}')", .{ name, path }),
        else => errExit("open '{s}' failed with {t}", .{ path, err }),
    };
    return .{ .dir = dir, .path = path };
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub const hash_version: u32 = 1;

const input_hash_name = "input_hash";

// cor.h: MAX_CLASS_NAME and MAX_PACKAGE_NAME are both 1024, the CLR's limit on a type name
// and on a namespace; an assembly's simple name is held to the same bound here
const max_class_name = 1024;
const max_escaped_name = max_class_name * "%XX".len;
// <assembly>\<namespace>.<type>~<suffix>.cs
const max_rel_path = 3 * max_escaped_name + "\\".len + ".".len + "~4294967295.cs".len;

pub const Funcs = struct {
    domain_get: *const dotnet.shared.domain_get,
    get_root_domain: *const dotnet.shared.get_root_domain,
    thread_attach: *const dotnet.shared.thread_attach,
    assembly_get_image: *const dotnet.shared.assembly_get_image,
    class_from_type: *const dotnet.shared.class_from_type,
    class_get_name: *const dotnet.shared.class_get_name,
    class_get_namespace: *const dotnet.shared.class_get_namespace,
    class_get_parent: *const dotnet.shared.class_get_parent,
    class_get_type: *const dotnet.shared.class_get_type,
    class_get_fields: *const dotnet.shared.class_get_fields,
    class_get_methods: *const dotnet.shared.class_get_methods,
    class_get_flags: *const dotnet.shared.class_get_flags,
    class_get_interfaces: *const dotnet.shared.class_get_interfaces,
    class_get_nested_types: *const dotnet.shared.class_get_nested_types,
    class_enum_basetype: *const dotnet.shared.class_enum_basetype,
    field_get_flags: *const dotnet.shared.field_get_flags,
    field_get_name: *const dotnet.shared.field_get_name,
    field_get_type: *const dotnet.shared.field_get_type,
    method_get_flags: *const dotnet.shared.method_get_flags,
    method_get_name: *const dotnet.shared.method_get_name,
    type_get_type: *const dotnet.shared.type_get_type,
    type_get_name: *const dotnet.shared.type_get_name,
    object_unbox: *const dotnet.shared.object_unbox,
    string_chars: *const dotnet.shared.string_chars,
    string_length: *const dotnet.shared.string_length,
    free: *const dotnet.shared.free,
    kind: union(dotnet.Kind) {
        mono: struct {
            jit_init: *const dotnet.mono.jit_init,
            set_assemblies_path: *const dotnet.mono.set_assemblies_path,
            assembly_open: *const dotnet.mono.assembly_open,
            image_get_name: *const dotnet.mono.image_get_name,
            image_get_table_info: *const dotnet.mono.image_get_table_info,
            table_info_get_rows: *const dotnet.mono.table_info_get_rows,
            class_get: *const dotnet.mono.class_get,
            class_get_nesting_type: *const dotnet.mono.class_get_nesting_type,
            class_is_valuetype: *const dotnet.mono.class_is_valuetype,
            class_is_enum: *const dotnet.mono.class_is_enum,
            method_signature: *const dotnet.mono.method_signature,
            signature_get_return_type: *const dotnet.mono.signature_get_return_type,
            signature_get_params: *const dotnet.mono.signature_get_params,
            signature_get_param_count: *const dotnet.mono.signature_get_param_count,
            method_get_param_names: *const dotnet.mono.method_get_param_names,
            field_get_value_object: *const dotnet.mono.field_get_value_object,
        },
        il2cpp: struct {
            init: *const dotnet.il2cpp.init,
            set_data_dir: *const dotnet.il2cpp.set_data_dir,
            domain_get_assemblies: *const dotnet.il2cpp.domain_get_assemblies,
            assembly_get_image: *const dotnet.il2cpp.assembly_get_image,
            image_get_name: *const dotnet.il2cpp.image_get_name,
            image_get_class_count: *const dotnet.il2cpp.image_get_class_count,
            image_get_class: *const dotnet.il2cpp.image_get_class,
            class_get_declaring_type: *const dotnet.il2cpp.class_get_declaring_type,
            class_is_valuetype: *const dotnet.il2cpp.class_is_valuetype,
            class_is_enum: *const dotnet.il2cpp.class_is_enum,
            method_get_return_type: *const dotnet.il2cpp.method_get_return_type,
            method_get_param_count: *const dotnet.il2cpp.method_get_param_count,
            method_get_param: *const dotnet.il2cpp.method_get_param,
            method_get_param_name: *const dotnet.il2cpp.method_get_param_name,
            field_static_get_value: *const dotnet.il2cpp.field_static_get_value,
        },
    },

    pub const class_is_enum = dotnet.class_is_enum;
    pub const class_is_valuetype = dotnet.class_is_valuetype;
    pub const class_get_declaring_type = dotnet.class_get_declaring_type;
};

// the exe's directory plus the longest suffix derived from it
const max_input_path = appdata.max_exepath + "\\MonoBleedingEdge\\EmbedRuntime\\".len + dotnet.dll_name_mono.len;

const InputBufs = struct {
    dll: [max_input_path]u8,
    dir: [max_input_path]u8,
    extra: [max_input_path]u8,
};

pub const Inputs = struct {
    name: []const u8,
    runtime: union(dotnet.Kind) {
        mono: struct { dll: [:0]u8, managed_dir: [:0]const u8 },
        il2cpp: struct { dll: [:0]u8, data_dir: [:0]const u8, metadata: []const u8 },
    },

    fn fromExe(exe: []const u8, bufs: *InputBufs) error{Reported}!Inputs {
        const dir = std.fs.path.dirname(exe) orelse return fail("'{s}' has no directory part", .{exe});
        const name = try nameFromExe(exe);

        const il2cpp_dll = std.fmt.bufPrintZ(&bufs.dll, "{s}\\{s}", .{ dir, dotnet.dll_name_il2cpp }) catch return fail("the path of '{s}' is too long", .{exe});
        if (exists(il2cpp_dll)) {
            const data_dir = std.fmt.bufPrintZ(&bufs.dir, "{s}\\{s}_Data\\il2cpp_data", .{ dir, name }) catch return fail("the path of '{s}' is too long", .{exe});
            const metadata = std.fmt.bufPrint(&bufs.extra, "{s}\\Metadata\\global-metadata.dat", .{data_dir}) catch return fail("the path of '{s}' is too long", .{exe});
            if (!exists(metadata)) return fail("'{s}' exists but '{s}' does not", .{ il2cpp_dll, metadata });
            return .{ .name = name, .runtime = .{ .il2cpp = .{ .dll = il2cpp_dll, .data_dir = data_dir, .metadata = metadata } } };
        }

        const mono_dll = std.fmt.bufPrintZ(&bufs.dll, "{s}\\MonoBleedingEdge\\EmbedRuntime\\{s}", .{ dir, dotnet.dll_name_mono }) catch return fail("the path of '{s}' is too long", .{exe});
        const managed = std.fmt.bufPrintZ(&bufs.dir, "{s}\\{s}_Data\\Managed", .{ dir, name }) catch return fail("the path of '{s}' is too long", .{exe});
        if (!exists(mono_dll)) return fail(
            "'{s}' does not look like a Unity game: neither '{s}' nor 'MonoBleedingEdge\\EmbedRuntime\\{s}' exists beside it",
            .{ exe, dotnet.dll_name_il2cpp, dotnet.dll_name_mono },
        );
        if (!exists(managed)) return fail("'{s}' exists but '{s}' does not", .{ mono_dll, managed });
        return .{ .name = name, .runtime = .{ .mono = .{ .dll = mono_dll, .managed_dir = managed } } };
    }
};

fn nameFromExe(exe: []const u8) error{Reported}![]const u8 {
    const basename = std.fs.path.basename(exe);
    const name = if (std.mem.endsWith(u8, basename, ".exe")) basename[0 .. basename.len - ".exe".len] else basename;
    if (name.len == 0) return fail("'{s}' has no file name", .{exe});
    return name;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            std.log.warn("access '{s}' failed with {t}", .{ path, err });
            return false;
        },
    };
    return true;
}

const Totals = struct {
    assemblies: usize = 0,
    types: usize = 0,
    updated: usize = 0,
    unchanged: usize = 0,
    failed: usize = 0,
};

const Status = enum { updated, unchanged, failed };

const AssemblyReport = struct { types: usize, status: Status };

fn gameCode(assembly_name: []const u8) bool {
    return std.mem.startsWith(u8, assembly_name, "Assembly-CSharp");
}

pub fn run(arena: std.mem.Allocator, inputs: Inputs, out: std.fs.Dir, output: *std.fs.File.Writer) error{Reported}!Totals {
    const host = switch (inputs.runtime) {
        .mono => |m| try dotnethost.load(Funcs, "mutiny", .mono, m.dll, .{ .assembly_path = m.managed_dir }),
        .il2cpp => |i| try dotnethost.load(Funcs, "mutiny", .il2cpp, i.dll, .{ .data_dir = i.data_dir }),
    };
    try host.attachThread();
    const funcs = &host.funcs;

    const il2cpp_hash: ?[32]u8 = switch (inputs.runtime) {
        .mono => null,
        .il2cpp => |i| try hashFiles(&.{ i.dll, i.metadata }),
    };

    var totals: Totals = .{};
    var dir_names: std.ArrayList([]const u8) = .empty;
    var discovery = try Discovery.init(funcs, inputs, host.domain);
    defer discovery.deinit();
    while (try discovery.next()) |found| {
        totals.assemblies += 1;
        {
            var escaped_buf: [max_escaped_name]u8 = undefined;
            const escaped = try escapeName(found.name, &escaped_buf);
            dir_names.append(arena, arena.dupe(u8, escaped) catch |e| oom(e)) catch |e| oom(e);
        }
        const report: AssemblyReport = blk: {
            const image = found.image orelse break :blk .{ .types = 0, .status = .failed };
            const hash = il2cpp_hash orelse try hashFiles(&.{found.path.?});
            break :blk processAssembly(arena, funcs, out, found.name, image, hash) catch |err| switch (err) {
                error.Reported => .{ .types = 0, .status = .failed },
            };
        };
        totals.types += report.types;
        switch (report.status) {
            .updated => totals.updated += 1,
            .unchanged => totals.unchanged += 1,
            .failed => totals.failed += 1,
        }
        if (report.status != .unchanged or gameCode(found.name)) {
            output.interface.print("  {s}: {d} types, {t}{s}\n", .{
                found.name,
                report.types,
                report.status,
                if (gameCode(found.name)) "   <- the game's own code" else "",
            }) catch return fail("write to stdout failed with {t}", .{output.err.?});
        }
    }

    try removeStaleDirs(out, dir_names.items);
    return totals;
}

const Found = struct {
    name: []const u8,
    image: ?*const dotnet.Image,
    path: ?[:0]const u8,
};

const Discovery = struct {
    funcs: *const Funcs,
    kind: union(dotnet.Kind) {
        mono: struct {
            dir: std.fs.Dir,
            it: std.fs.Dir.Iterator,
            managed_dir: [:0]const u8,
            path_buf: [max_input_path + "\\".len + std.fs.max_name_bytes]u8,
        },
        il2cpp: struct {
            list: [*]const *const dotnet.Assembly,
            count: usize,
            next: usize,
        },
    },

    fn init(funcs: *const Funcs, inputs: Inputs, domain: *const dotnet.Domain) error{Reported}!Discovery {
        switch (inputs.runtime) {
            .mono => |m| {
                const dir = std.fs.openDirAbsolute(m.managed_dir, .{ .iterate = true }) catch |err| return fail(
                    "open '{s}' failed with {t}",
                    .{ m.managed_dir, err },
                );
                return .{ .funcs = funcs, .kind = .{ .mono = .{
                    .dir = dir,
                    .it = dir.iterate(),
                    .managed_dir = m.managed_dir,
                    .path_buf = undefined,
                } } };
            },
            .il2cpp => {
                var count: usize = 0;
                const list = funcs.kind.il2cpp.domain_get_assemblies(domain, &count);
                return .{ .funcs = funcs, .kind = .{ .il2cpp = .{ .list = list, .count = count, .next = 0 } } };
            },
        }
    }

    fn deinit(d: *Discovery) void {
        switch (d.kind) {
            .mono => |*m| m.dir.close(),
            .il2cpp => {},
        }
    }

    fn next(d: *Discovery) error{Reported}!?Found {
        switch (d.kind) {
            .mono => |*m| {
                const mono = &d.funcs.kind.mono;
                while (m.it.next() catch |err| return fail("list '{s}' failed with {t}", .{ m.managed_dir, err })) |entry| {
                    if (entry.kind != .file) continue;
                    if (!std.ascii.endsWithIgnoreCase(entry.name, ".dll")) continue;
                    const path = std.fmt.bufPrintZ(&m.path_buf, "{s}\\{s}", .{ m.managed_dir, entry.name }) catch |err| switch (err) {
                        error.NoSpaceLeft => return fail("the path of '{s}' in '{s}' is too long", .{ entry.name, m.managed_dir }),
                    };
                    const file_name = path[m.managed_dir.len + 1 .. path.len - ".dll".len];
                    var status: dotnet.MonoImageOpenStatus = .ok;
                    const maybe_assembly = mono.assembly_open(path, &status);
                    if (status == .image_invalid) {
                        std.log.info("{s}: not a managed assembly, skipped", .{entry.name});
                        continue;
                    }
                    const assembly = maybe_assembly orelse {
                        std.log.err("{s}: mono_assembly_open failed with {t}", .{ entry.name, status });
                        return .{ .name = file_name, .image = null, .path = path };
                    };
                    if (status != .ok) {
                        std.log.err("{s}: mono_assembly_open gave status {t}", .{ entry.name, status });
                        return .{ .name = file_name, .image = null, .path = path };
                    }
                    const image = d.funcs.assembly_get_image(assembly) orelse {
                        std.log.err("{s}: mono_assembly_get_image returned null", .{entry.name});
                        return .{ .name = file_name, .image = null, .path = path };
                    };
                    return .{ .name = std.mem.span(mono.image_get_name(image)), .image = image, .path = path };
                }
                return null;
            },
            .il2cpp => |*i| {
                const il2cpp = &d.funcs.kind.il2cpp;
                while (i.next < i.count) {
                    const assembly = i.list[i.next];
                    i.next += 1;
                    const image = il2cpp.assembly_get_image(assembly);
                    const image_name = std.mem.span(il2cpp.image_get_name(image));
                    if (std.mem.eql(u8, image_name, "__Generated")) continue;
                    const name = if (std.mem.endsWith(u8, image_name, ".dll")) image_name[0 .. image_name.len - ".dll".len] else image_name;
                    return .{ .name = name, .image = image, .path = null };
                }
                return null;
            },
        }
    }
};

fn removeStaleDirs(out: std.fs.Dir, dir_names: []const []const u8) error{Reported}!void {
    var it = out.iterate();
    while (it.next() catch |err| return fail("list the decomp directory failed with {t}", .{err})) |entry| {
        if (entry.kind != .directory) continue;
        if (contains(dir_names, entry.name)) continue;
        var name_buf: [std.fs.max_name_bytes]u8 = undefined;
        @memcpy(name_buf[0..entry.name.len], entry.name);
        const name = name_buf[0..entry.name.len];
        std.log.info("{s}: no longer in the game, removed", .{name});
        out.deleteTree(name) catch |err| return fail("delete '{s}' failed with {t}", .{ name, err });
    }
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn hashFiles(paths: []const []const u8) error{Reported}![32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (paths) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| return fail("open '{s}' failed with {t}", .{ path, err });
        defer file.close();
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const len = file.read(&buf) catch |err| return fail("read '{s}' failed with {t}", .{ path, err });
            if (len == 0) break;
            hasher.update(buf[0..len]);
        }
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

const Ctx = struct {
    arena: std.mem.Allocator,
    funcs: *const Funcs,
    out: std.fs.Dir,
    assembly_name: []const u8,
    dir_name: []const u8,
    count: usize = 0,
};

const input_hash_len = std.fmt.comptimePrint("hash_version {d}\nhash {s}\n", .{ hash_version, "0" ** 64 }).len;
const input_hash_path_len = max_escaped_name + "\\".len + input_hash_name.len;

fn processAssembly(
    arena: std.mem.Allocator,
    funcs: *const Funcs,
    out: std.fs.Dir,
    assembly_name: []const u8,
    image: *const dotnet.Image,
    hash: [32]u8,
) error{Reported}!AssemblyReport {
    var dir_name_buf: [max_escaped_name]u8 = undefined;
    const dir_name = try escapeName(assembly_name, &dir_name_buf);

    var input_hash_buf: [input_hash_len]u8 = undefined;
    const input_hash = std.fmt.bufPrint(&input_hash_buf, "hash_version {d}\nhash {s}\n", .{
        hash_version,
        std.fmt.bytesToHex(hash, .lower),
    }) catch |err| switch (err) {
        error.NoSpaceLeft => return fail("the input_hash text for '{s}' does not fit its buffer", .{assembly_name}),
    };
    var input_hash_path_buf: [input_hash_path_len]u8 = undefined;
    const input_hash_path = std.fmt.bufPrint(&input_hash_path_buf, "{s}\\{s}", .{ dir_name, input_hash_name }) catch |err| switch (err) {
        error.NoSpaceLeft => return fail("the input_hash path for '{s}' does not fit its buffer", .{assembly_name}),
    };

    if (try inputHashMatches(out, input_hash_path, input_hash)) {
        return .{ .types = try countFiles(out, dir_name), .status = .unchanged };
    }

    out.deleteTree(dir_name) catch |err| return fail("delete '{s}' failed with {t}", .{ dir_name, err });
    out.makePath(dir_name) catch |err| return fail("create '{s}' failed with {t}", .{ dir_name, err });

    var ctx: Ctx = .{
        .arena = arena,
        .funcs = funcs,
        .out = out,
        .assembly_name = assembly_name,
        .dir_name = dir_name,
    };
    var it: ClassIterator = .init(funcs, image);
    while (it.next()) |class| {
        if (funcs.class_get_declaring_type(class) != null) continue;
        try writeTopLevelFile(&ctx, class);
    }

    out.writeFile(.{ .sub_path = input_hash_path, .data = input_hash }) catch |err| return fail("write '{s}' failed with {t}", .{ input_hash_path, err });
    return .{ .types = ctx.count, .status = .updated };
}

fn inputHashMatches(out: std.fs.Dir, path: []const u8, input_hash: []const u8) error{Reported}!bool {
    const file = out.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return fail("open '{s}' failed with {t}", .{ path, err }),
    };
    defer file.close();
    var buf: [input_hash_len + 1]u8 = undefined;
    const len = file.readAll(&buf) catch |err| return fail("read '{s}' failed with {t}", .{ path, err });
    return std.mem.eql(u8, buf[0..len], input_hash);
}

fn countFiles(out: std.fs.Dir, dir_name: []const u8) error{Reported}!usize {
    var dir = out.openDir(dir_name, .{ .iterate = true }) catch |err| return fail("open '{s}' failed with {t}", .{ dir_name, err });
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch |err| return fail("list '{s}' failed with {t}", .{ dir_name, err })) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".cs")) count += 1;
    }
    return count;
}

const ClassIterator = union(dotnet.Kind) {
    mono: struct { funcs: *const Funcs, image: *const dotnet.Image, next_row: u32, rows: u32 },
    il2cpp: struct { funcs: *const Funcs, image: *const dotnet.Image, next: usize, count: usize },

    fn init(funcs: *const Funcs, image: *const dotnet.Image) ClassIterator {
        return switch (funcs.kind) {
            .mono => |*mono| .{ .mono = .{
                .funcs = funcs,
                .image = image,
                .next_row = 1,
                .rows = blk: {
                    const table = mono.image_get_table_info(image, dotnet.mono_table_typedef) orelse break :blk 0;
                    break :blk @intCast(mono.table_info_get_rows(table));
                },
            } },
            .il2cpp => |*il2cpp| .{ .il2cpp = .{
                .funcs = funcs,
                .image = image,
                .next = 0,
                .count = il2cpp.image_get_class_count(image),
            } },
        };
    }

    fn next(it: *ClassIterator) ?*const dotnet.Class {
        switch (it.*) {
            .mono => |*m| while (m.next_row <= m.rows) {
                const row = m.next_row;
                m.next_row += 1;
                if (m.funcs.kind.mono.class_get(m.image, dotnet.mono_token_type_def | row)) |class| return class;
                std.log.warn("{s}: typedef row {} did not load", .{ m.funcs.kind.mono.image_get_name(m.image), row });
            },
            .il2cpp => |*i| if (i.next < i.count) {
                const class = i.funcs.kind.il2cpp.image_get_class(i.image, i.next);
                i.next += 1;
                return class;
            },
        }
        return null;
    }
};

const ClassKind = enum { class, @"struct", @"enum", interface, delegate };

fn classKind(funcs: *const Funcs, class: *const dotnet.Class, flags: dotnet.ClassFlags) ClassKind {
    if (flags.interface) return .interface;
    if (funcs.class_is_enum(class)) return .@"enum";
    if (funcs.class_is_valuetype(class)) return .@"struct";
    if (funcs.class_get_parent(class)) |parent| {
        if (isSystemClass(funcs, parent, "MulticastDelegate")) return .delegate;
    }
    return .class;
}

fn isSystemClass(funcs: *const Funcs, class: *const dotnet.Class, name: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(funcs.class_get_namespace(class)), "System") and
        std.mem.eql(u8, std.mem.span(funcs.class_get_name(class)), name);
}

fn implicitBase(funcs: *const Funcs, parent: *const dotnet.Class) bool {
    for ([_][]const u8{ "Object", "ValueType", "Enum", "MulticastDelegate" }) |name| {
        if (isSystemClass(funcs, parent, name)) return true;
    }
    return false;
}

fn generated(name: []const u8) bool {
    return name.len == 0 or name[0] == '<';
}

fn writeTopLevelFile(ctx: *Ctx, class: *const dotnet.Class) error{Reported}!void {
    const funcs = ctx.funcs;
    const name = std.mem.span(funcs.class_get_name(class));
    if (generated(name)) return;
    const namespace = std.mem.span(funcs.class_get_namespace(class));

    var escaped_ns_buf: [max_escaped_name]u8 = undefined;
    const escaped_ns = try escapeName(namespace, &escaped_ns_buf);
    var escaped_name_buf: [max_escaped_name]u8 = undefined;
    const escaped_name = try escapeName(name, &escaped_name_buf);
    const dot: []const u8 = if (namespace.len == 0) "" else ".";

    var rel_buf: [max_rel_path]u8 = undefined;
    var suffix: u32 = 1;
    var rel: []const u8 = undefined;
    const file = while (true) : (suffix += 1) {
        rel = (if (suffix == 1)
            std.fmt.bufPrint(&rel_buf, "{s}\\{s}{s}{s}.cs", .{ ctx.dir_name, escaped_ns, dot, escaped_name })
        else
            std.fmt.bufPrint(&rel_buf, "{s}\\{s}{s}{s}~{d}.cs", .{ ctx.dir_name, escaped_ns, dot, escaped_name, suffix })) catch |err| switch (err) {
            error.NoSpaceLeft => return fail("the path for '{s}.{s}' does not fit its buffer", .{ namespace, name }),
        };
        break ctx.out.createFile(rel, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return fail("create '{s}' failed with {t}", .{ rel, err }),
        };
    };
    defer file.close();
    var file_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    const w = &file_writer.interface;

    writeFile(ctx, w, class, namespace, name) catch return fail("write '{s}' failed with {t}", .{ rel, file_writer.err.? });
    w.flush() catch return fail("write '{s}' failed with {t}", .{ rel, file_writer.err.? });
    ctx.count += 1;
}

fn writeFile(
    ctx: *Ctx,
    w: *std.Io.Writer,
    class: *const dotnet.Class,
    namespace: []const u8,
    name: []const u8,
) error{WriteFailed}!void {
    try w.print("// assembly {s}\n", .{ctx.assembly_name});
    if (namespace.len != 0) try w.print("namespace {s} {{\n\n", .{namespace});
    try writeTypeDecl(ctx, w, class, name, 0);
    if (namespace.len != 0) try w.writeAll("\n}\n");
}

fn writeIndent(w: *std.Io.Writer, level: usize) error{WriteFailed}!void {
    try w.splatByteAll(' ', level * 4);
}

fn writeTypeDecl(
    ctx: *Ctx,
    w: *std.Io.Writer,
    class: *const dotnet.Class,
    name: []const u8,
    level: usize,
) error{WriteFailed}!void {
    const funcs = ctx.funcs;
    const flags = funcs.class_get_flags(class);
    const kind = classKind(funcs, class, flags);

    try writeIndent(w, level);
    try w.writeAll(switch (flags.visibility) {
        .public, .nested_public => "public",
        .not_public, .nested_assembly => "internal",
        .nested_private => "private",
        .nested_family => "protected",
        .nested_fam_or_assem => "protected internal",
        .nested_fam_and_assem => "private protected",
    });

    if (kind == .delegate) {
        if (findMethod(funcs, class, "Invoke")) |invoke| {
            try w.writeAll(" delegate ");
            try writeReturnType(ctx, w, invoke);
            try w.print(" {s}(", .{name});
            try writeParams(ctx, w, invoke);
            try w.writeAll(");\n");
            return;
        }
    }

    if (kind == .class) {
        if (flags.abstract and flags.sealed) {
            try w.writeAll(" static");
        } else if (flags.abstract) {
            try w.writeAll(" abstract");
        } else if (flags.sealed) {
            try w.writeAll(" sealed");
        }
    }
    try w.print(" {t} {s}", .{ kind, name });
    var separator: []const u8 = " : ";
    if (funcs.class_get_parent(class)) |parent| if (!implicitBase(funcs, parent)) {
        try w.writeAll(separator);
        try writeClassName(funcs, w, parent);
        separator = ", ";
    };
    var interfaces: ?*anyopaque = null;
    while (funcs.class_get_interfaces(class, &interfaces)) |interface| {
        try w.writeAll(separator);
        try writeClassName(funcs, w, interface);
        separator = ", ";
    }
    try w.writeByte('\n');
    try writeIndent(w, level);
    try w.writeAll("{\n");

    if (kind == .@"enum") {
        var fields: ?*anyopaque = null;
        while (funcs.class_get_fields(class, &fields)) |field| {
            if (!funcs.field_get_flags(field).literal) continue;
            try writeIndent(w, level + 1);
            try w.writeAll(std.mem.span(funcs.field_get_name(field)));
            try writeConstValue(ctx, w, field);
            try w.writeAll(",\n");
        }
        try writeIndent(w, level);
        try w.writeAll("}\n");
        return;
    }

    var wrote_section = false;
    var fields: ?*anyopaque = null;
    while (funcs.class_get_fields(class, &fields)) |field| {
        try writeField(ctx, w, field, level + 1);
        wrote_section = true;
    }
    var wrote_method = false;
    var methods: ?*anyopaque = null;
    while (funcs.class_get_methods(class, &methods)) |method| {
        if (wrote_section and !wrote_method) try w.writeByte('\n');
        try writeMethod(ctx, w, method, level + 1);
        wrote_method = true;
        wrote_section = true;
    }
    var nested: ?*anyopaque = null;
    while (funcs.class_get_nested_types(class, &nested)) |nested_class| {
        const nested_name = std.mem.span(funcs.class_get_name(nested_class));
        if (generated(nested_name)) continue;
        if (wrote_section) try w.writeByte('\n');
        try writeTypeDecl(ctx, w, nested_class, nested_name, level + 1);
        wrote_section = true;
    }
    try writeIndent(w, level);
    try w.writeAll("}\n");
}

fn findMethod(funcs: *const Funcs, class: *const dotnet.Class, name: []const u8) ?*const dotnet.Method {
    var methods: ?*anyopaque = null;
    while (funcs.class_get_methods(class, &methods)) |method| {
        if (std.mem.eql(u8, std.mem.span(funcs.method_get_name(method)), name)) return method;
    }
    return null;
}

fn protectionWord(protection: dotnet.Protection) []const u8 {
    return switch (protection) {
        .public => "public",
        .private, .compiler_controlled => "private",
        .family => "protected",
        .assem => "internal",
        .fam_or_assem => "protected internal",
        .fam_and_assem => "private protected",
    };
}

fn writeField(ctx: *Ctx, w: *std.Io.Writer, field: *const dotnet.ClassField, level: usize) error{WriteFailed}!void {
    const funcs = ctx.funcs;
    const flags = funcs.field_get_flags(field);
    try writeIndent(w, level);
    try w.writeAll(protectionWord(flags.protection));
    if (flags.literal) {
        try w.writeAll(" const");
    } else {
        if (flags.static) try w.writeAll(" static");
        if (flags.init_only) try w.writeAll(" readonly");
    }
    try w.writeByte(' ');
    try writeTypeName(funcs, w, funcs.field_get_type(field));
    try w.print(" {s}", .{funcs.field_get_name(field)});
    if (flags.literal) try writeConstValue(ctx, w, field);
    try w.writeAll(";\n");
}

fn writeMethod(ctx: *Ctx, w: *std.Io.Writer, method: *const dotnet.Method, level: usize) error{WriteFailed}!void {
    const funcs = ctx.funcs;
    var impl: dotnet.MethodImplFlags = undefined;
    const flags = funcs.method_get_flags(method, &impl);
    const name = std.mem.span(funcs.method_get_name(method));
    try writeIndent(w, level);
    try w.writeAll(protectionWord(@enumFromInt(@intFromEnum(flags.protection))));
    if (flags.static) try w.writeAll(" static");
    if (flags.abstract) {
        try w.writeAll(" abstract");
    } else if (flags.virtual) {
        try w.writeAll(if (flags.new_slot) " virtual" else " override");
    }
    if (impl.internal_call or flags.pinvoke_impl) try w.writeAll(" extern");
    const is_ctor = std.mem.eql(u8, name, ".ctor") or std.mem.eql(u8, name, ".cctor");
    if (!is_ctor) {
        try w.writeByte(' ');
        try writeReturnType(ctx, w, method);
    }
    try w.print(" {s}(", .{name});
    try writeParams(ctx, w, method);
    try w.writeAll(");\n");
}

fn writeReturnType(ctx: *Ctx, w: *std.Io.Writer, method: *const dotnet.Method) error{WriteFailed}!void {
    const funcs = ctx.funcs;
    const return_type: ?*const dotnet.Type = switch (funcs.kind) {
        .mono => |*mono| if (mono.method_signature(method)) |sig| mono.signature_get_return_type(sig) else null,
        .il2cpp => |*il2cpp| il2cpp.method_get_return_type(method),
    };
    if (return_type) |t| try writeTypeName(funcs, w, t) else try w.writeByte('?');
}

fn writeParams(ctx: *Ctx, w: *std.Io.Writer, method: *const dotnet.Method) error{WriteFailed}!void {
    const funcs = ctx.funcs;
    switch (funcs.kind) {
        .mono => |*mono| {
            const sig = mono.method_signature(method) orelse return w.writeByte('?');
            const count = mono.signature_get_param_count(sig);
            const names = ctx.arena.alloc(?[*:0]const u8, count) catch |e| oom(e);
            defer ctx.arena.free(names);
            @memset(names, null);
            mono.method_get_param_names(method, names.ptr);
            var iter: ?*anyopaque = null;
            var i: usize = 0;
            while (mono.signature_get_params(sig, &iter)) |param_type| : (i += 1) {
                if (i != 0) try w.writeAll(", ");
                try writeTypeName(funcs, w, param_type);
                if (i < names.len) {
                    if (names[i]) |param_name| try w.print(" {s}", .{param_name}) else try w.print(" arg{d}", .{i});
                }
            }
        },
        .il2cpp => |*il2cpp| {
            const count = il2cpp.method_get_param_count(method);
            for (0..count) |i| {
                if (i != 0) try w.writeAll(", ");
                try writeTypeName(funcs, w, il2cpp.method_get_param(method, @intCast(i)));
                try w.print(" {s}", .{il2cpp.method_get_param_name(method, @intCast(i))});
            }
        },
    }
}

fn writeClassName(funcs: *const Funcs, w: *std.Io.Writer, class: *const dotnet.Class) error{WriteFailed}!void {
    try writeTypeName(funcs, w, funcs.class_get_type(class));
}

fn writeTypeName(funcs: *const Funcs, w: *std.Io.Writer, t: *const dotnet.Type) error{WriteFailed}!void {
    const raw = funcs.type_get_name(t) orelse return w.writeByte('?');
    defer funcs.free(@ptrCast(raw));
    const name = std.mem.span(raw);
    var i: usize = 0;
    while (i < name.len) {
        const start = i;
        while (i < name.len and isNameChar(name[i])) i += 1;
        if (i > start) {
            const word = name[start..i];
            try w.writeAll(primitive_names.get(word) orelse word);
        }
        if (i < name.len) {
            try w.writeByte(if (name[i] == '/') '.' else name[i]);
            i += 1;
        }
    }
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '`' or c >= 0x80;
}

const primitive_names = std.StaticStringMap([]const u8).initComptime(.{
    .{ "System.Void", "void" },
    .{ "System.Boolean", "bool" },
    .{ "System.Char", "char" },
    .{ "System.SByte", "sbyte" },
    .{ "System.Byte", "byte" },
    .{ "System.Int16", "short" },
    .{ "System.UInt16", "ushort" },
    .{ "System.Int32", "int" },
    .{ "System.UInt32", "uint" },
    .{ "System.Int64", "long" },
    .{ "System.UInt64", "ulong" },
    .{ "System.Single", "float" },
    .{ "System.Double", "double" },
    .{ "System.String", "string" },
    .{ "System.Object", "object" },
});

fn valueKind(funcs: *const Funcs, t: *const dotnet.Type) dotnet.TypeKind {
    const kind = funcs.type_get_type(t);
    if (kind != .valuetype) return kind;
    const class = funcs.class_from_type(t) orelse return kind;
    if (!funcs.class_is_enum(class)) return kind;
    return funcs.type_get_type(funcs.class_enum_basetype(class));
}

fn read(comptime T: type, value: *const anyopaque) T {
    const typed: *align(1) const T = @ptrCast(value);
    return typed.*;
}

fn writeConstValue(ctx: *Ctx, w: *std.Io.Writer, field: *const dotnet.ClassField) error{WriteFailed}!void {
    const funcs = ctx.funcs;
    const kind = valueKind(funcs, funcs.field_get_type(field));
    var raw: [16]u8 align(16) = @splat(0);
    if (kind == .string) {
        const string: *const dotnet.String = switch (funcs.kind) {
            .mono => |*mono| @ptrCast(mono.field_get_value_object(funcs.domain_get().?, field, null) orelse return),
            .il2cpp => |*il2cpp| blk: {
                il2cpp.field_static_get_value(field, &raw);
                break :blk read(?*const dotnet.String, &raw) orelse return;
            },
        };
        try w.writeAll(" = ");
        try writeStringLiteral(ctx, w, string);
        return;
    }
    const value: *const anyopaque = switch (funcs.kind) {
        .mono => |*mono| funcs.object_unbox(mono.field_get_value_object(funcs.domain_get().?, field, null) orelse return),
        .il2cpp => |*il2cpp| blk: {
            il2cpp.field_static_get_value(field, &raw);
            break :blk &raw;
        },
    };
    switch (kind) {
        .boolean => try w.writeAll(if (read(u8, value) != 0) " = true" else " = false"),
        .char => try writeCharLiteral(w, read(u16, value)),
        .i1 => try w.print(" = {d}", .{read(i8, value)}),
        .u1 => try w.print(" = {d}", .{read(u8, value)}),
        .i2 => try w.print(" = {d}", .{read(i16, value)}),
        .u2 => try w.print(" = {d}", .{read(u16, value)}),
        .i4 => try w.print(" = {d}", .{read(i32, value)}),
        .u4 => try w.print(" = {d}", .{read(u32, value)}),
        .i8 => try w.print(" = {d}", .{read(i64, value)}),
        .u8 => try w.print(" = {d}", .{read(u64, value)}),
        .r4 => try w.print(" = {d}", .{read(f32, value)}),
        .r8 => try w.print(" = {d}", .{read(f64, value)}),
        else => {},
    }
}

fn writeCharLiteral(w: *std.Io.Writer, c: u16) error{WriteFailed}!void {
    if (c >= 0x20 and c < 0x7f and c != '\'' and c != '\\') {
        try w.print(" = '{c}'", .{@as(u8, @intCast(c))});
    } else {
        try w.print(" = '\\u{X:0>4}'", .{c});
    }
}

fn writeStringLiteral(ctx: *Ctx, w: *std.Io.Writer, string: *const dotnet.String) error{WriteFailed}!void {
    const len: usize = @intCast(ctx.funcs.string_length(string));
    const chars = ctx.funcs.string_chars(string)[0..len];
    try w.writeByte('"');
    var it = std.unicode.Wtf16LeIterator.init(chars);
    while (it.nextCodepoint()) |codepoint| switch (codepoint) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (codepoint < 0x20) {
            try w.print("\\u{X:0>4}", .{codepoint});
        } else {
            var utf8: [4]u8 = undefined;
            const utf8_len = std.unicode.wtf8Encode(codepoint, &utf8) catch |err| switch (err) {
                error.CodepointTooLarge => return w.print("\\U{X:0>8}", .{codepoint}),
            };
            try w.writeAll(utf8[0..utf8_len]);
        },
    };
    try w.writeByte('"');
}

fn escapeName(name: []const u8, buf: *[max_escaped_name]u8) error{Reported}![]const u8 {
    if (name.len > max_class_name) return fail("'{s}' is longer than the CLR's MAX_CLASS_NAME of {d}", .{ name, max_class_name });
    var w = std.Io.Writer.fixed(buf);
    const reserved = isReservedDeviceName(name);
    for (name, 0..) |c, i| {
        const escape = switch (c) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*', '%' => true,
            '.', ' ' => i + 1 == name.len,
            else => c < 0x20 or (i == 0 and reserved),
        };
        (if (escape) w.print("%{X:0>2}", .{c}) else w.writeByte(c)) catch |err| switch (err) {
            error.WriteFailed => return fail("escaping '{s}' overflowed a buffer sized for MAX_CLASS_NAME", .{name}),
        };
    }
    return w.buffered();
}

fn isReservedDeviceName(name: []const u8) bool {
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') {
        if (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) return true;
    }
    return false;
}

fn fail(comptime fmt: []const u8, args: anytype) error{Reported} {
    std.log.err(fmt, args);
    return error.Reported;
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const mutiny = @import("mutiny");
const appdata = mutiny.appdata;
const dotnet = mutiny.dotnet;
const dotnethost = mutiny.dotnethost;
