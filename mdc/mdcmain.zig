pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    var opt_source_path: ?[]const u8 = null;
    var opt_out_path: ?[]const u8 = null;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "-o")) {
                i += 1;
                if (i == args.len) errExit("-o requires an argument", .{});
                if (opt_out_path != null) errExit("-o given more than once", .{});
                opt_out_path = args[i];
            } else if (a.len > 0 and a[0] == '-') {
                errExit("unknown option '{s}'", .{a});
            } else {
                if (opt_source_path != null) errExit("too many source files", .{});
                opt_source_path = a;
            }
        }
    }
    const source_path = opt_source_path orelse errExit("usage: mdc SOURCE -o OUT", .{});
    const out_path = opt_out_path orelse errExit("no output file, need -o OUT", .{});

    const source = std.fs.cwd().readFileAlloc(arena, source_path, std.math.maxInt(u32)) catch |err| errExit(
        "read '{s}' failed with {t}",
        .{ source_path, err },
    );

    var parsed: Parsed = .{};
    var model: metadata.Model = .{ .arena = arena, .path = source_path };
    parse(arena, &parsed, &model, source_path, source);

    const generated = metadata.finish(&model, section_alignment + 8 + @sizeOf(CliHeader));
    for ([_]struct { Region, []const u8 }{
        .{ .bodies, generated.bodies },
        .{ .tables, generated.tables },
        .{ .strings, generated.strings },
        .{ .us, generated.us },
        .{ .blob, generated.blob },
    }) |g| {
        if (g[1].len == 0) continue;
        const region = parsed.regions.getPtr(g[0]);
        if (region.items.len > 0) errExit(
            "both hex and directives given for the {t} region",
            .{g[0]},
        );
        region.appendSlice(arena, g[1]) catch |err| errExit("{t}", .{err});
    }
    if (parsed.regions.get(.tables).items.len == 0) errExit("{s}: no metadata tables", .{source_path});

    const out = std.fs.cwd().createFile(out_path, .{}) catch |err| errExit(
        "create '{s}' failed with {t}",
        .{ out_path, err },
    );
    defer out.close();
    var buf: [4096]u8 = undefined;
    var out_writer = out.writer(&buf);
    write(&out_writer.interface, &parsed) catch |err| switch (err) {
        error.WriteFailed => return out_writer.err.?,
    };
}

const file_alignment = 0x200;
const section_alignment = 0x2000;
const image_base = 0x10000000;
const machine_i386 = 0x14c;
const coff_characteristics = 0x2102;
const optional_header_magic_pe32 = 0x10b;
const size_of_optional_header = 224;
const subsystem_windows_cui = 3;
const dll_characteristics = 0x8540;
const number_of_rva_and_sizes = 16;

const directory_import = 1;
const directory_resource = 2;
const directory_base_relocation = 5;
const directory_iat = 12;
const directory_cli_header = 14;

const Region = enum { bodies, tables, strings, us, guid, blob, rsrc };

const streams = [_]struct { Region, []const u8 }{
    .{ .tables, "#~" },
    .{ .strings, "#Strings" },
    .{ .us, "#US" },
    .{ .guid, "#GUID" },
    .{ .blob, "#Blob" },
};

const metadata_version = "v4.0.30319\x00\x00";

fn streamHeadersSize() u32 {
    var size: u32 = 0;
    for (streams) |s| {
        size += 8 + std.mem.alignForward(u32, @intCast(s[1].len + 1), 4);
    }
    return size;
}

fn metadataRootSize() u32 {
    return 16 + @as(u32, metadata_version.len) + 4 + streamHeadersSize();
}

const Parsed = struct {
    timestamp: u32 = 0,
    version: ?Version = null,
    regions: std.EnumArray(Region, std.ArrayListUnmanaged(u8)) = .initFill(.{}),
};

const Version = struct {
    file_name: []const u8,
    number: []const u8,
};

fn parse(
    arena: std.mem.Allocator,
    parsed: *Parsed,
    model: *metadata.Model,
    path: []const u8,
    source: []const u8,
) void {
    var current: ?Region = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var lineno: u32 = 0;
    while (lines.next()) |raw_line| {
        lineno += 1;
        const uncommented = if (std.mem.indexOfScalar(u8, raw_line, '#')) |i| raw_line[0..i] else raw_line;
        const line = std.mem.trim(u8, uncommented, " \t\r");
        if (line.len == 0) continue;

        const directive, var rest = splitDirective(line);
        if (metadata.directive(model, path, lineno, directive, rest)) {
            // consumed by the metadata model
        } else if (std.meta.stringToEnum(Region, directive)) |region| {
            if (rest.len > 0) errExit("{s}:{}: trailing '{s}'", .{ path, lineno, rest });
            if (parsed.regions.get(region).items.len > 0) errExit(
                "{s}:{}: second '{s}' region",
                .{ path, lineno, directive },
            );
            current = region;
        } else if (std.mem.eql(u8, directive, "hex")) {
            const region = current orelse errExit(
                "{s}:{}: 'hex' before any region directive",
                .{ path, lineno },
            );
            appendHex(arena, parsed.regions.getPtr(region), path, lineno, rest);
        } else if (std.mem.eql(u8, directive, "timestamp")) {
            parsed.timestamp = parseInt(path, lineno, requireArg(path, lineno, &rest));
        } else if (std.mem.eql(u8, directive, "mvid")) {
            const guid = parseGuid(path, lineno, requireArg(path, lineno, &rest));
            const region = parsed.regions.getPtr(.guid);
            if (region.items.len > 0) errExit("{s}:{}: second mvid", .{ path, lineno });
            region.appendSlice(arena, &guid) catch |err| errExit("{t}", .{err});
        } else if (std.mem.eql(u8, directive, "version")) {
            if (parsed.version != null) errExit("{s}:{}: second version", .{ path, lineno });
            parsed.version = .{
                .file_name = parseQuoted(path, lineno, requireArg(path, lineno, &rest)),
                .number = parseQuoted(path, lineno, requireArg(path, lineno, &rest)),
            };
        } else errExit("{s}:{}: unknown directive '{s}'", .{ path, lineno, directive });
    }
}

fn streamSize(parsed: *const Parsed, region: Region) u32 {
    return std.mem.alignForward(u32, @intCast(parsed.regions.get(region).items.len), 4);
}

fn metadataSize(parsed: *const Parsed) u32 {
    var size = metadataRootSize();
    for (streams) |s| size += streamSize(parsed, s[0]);
    return size;
}

const CliHeader = extern struct {
    cb: u32,
    major_runtime_version: u16,
    minor_runtime_version: u16,
    metadata_rva: u32,
    metadata_size: u32,
    flags: u32,
    entry_point_token: u32,
    resources: [2]u32,
    strong_name_signature: [2]u32,
    code_manager_table: [2]u32,
    vtable_fixups: [2]u32,
    export_address_table_jumps: [2]u32,
    managed_native_header: [2]u32,
};

const cli_flags_il_only = 0x1;

const import_hint_name = "\x00\x00_CorDllMain\x00";
const import_dll_name = "mscoree.dll\x00\x00";
const import_table_size: u32 = 40 + 20 + 8 + import_hint_name.len + import_dll_name.len;

// Everything about where the pieces land, derived from the region lengths alone. The .text
// section is the mscoree shim that makes a pure-IL dll loadable - an import of _CorDllMain
// and a native entry stub jumping to it through the iat - wrapped around the two regions.
// Modern runtimes ignore the shim entirely.
const Layout = struct {
    iat_rva: u32,
    cli_rva: u32,
    bodies_rva: u32,
    metadata_rva: u32,
    import_rva: u32,
    ilt_rva: u32,
    hint_name_rva: u32,
    dll_name_rva: u32,
    import_end: u32,
    operand_rva: u32,
    entry_rva: u32,
    text: SectionLayout,
    rsrc: SectionLayout,
    reloc: SectionLayout,
    section_count: u16,
    size_of_headers: u32,
    size_of_image: u32,

    fn init(parsed: *const Parsed) Layout {
        const bodies_len: u32 = @intCast(parsed.regions.get(.bodies).items.len);
        const metadata_len = metadataSize(parsed);
        const rsrc_len: u32 = if (parsed.version) |v|
            rsrcSize(v)
        else
            @intCast(parsed.regions.get(.rsrc).items.len);
        const section_count: u16 = if (rsrc_len > 0) 3 else 2;

        const iat_rva: u32 = section_alignment;
        const cli_rva = iat_rva + 8;
        const bodies_rva = cli_rva + @sizeOf(CliHeader);
        const metadata_rva = bodies_rva + bodies_len;
        const import_rva = metadata_rva + metadata_len;
        const ilt_rva = import_rva + 40;
        const hint_name_rva = ilt_rva + 8;
        const dll_name_rva = hint_name_rva + @as(u32, import_hint_name.len);
        const import_end = dll_name_rva + @as(u32, import_dll_name.len);
        // ff 25 with its operand 4-aligned
        const operand_rva = std.mem.alignForward(u32, import_end + 2, 4);
        const text_size = operand_rva + 4 - iat_rva;

        const size_of_headers = std.mem.alignForward(u32, headersEnd(section_count), file_alignment);

        var next: SectionLayout = .{
            .virtual_address = section_alignment,
            .virtual_size = 0,
            .raw_offset = size_of_headers,
        };
        const text = next.take(text_size);
        const rsrc = next.take(rsrc_len);
        const reloc = next.take(12);

        return .{
            .iat_rva = iat_rva,
            .cli_rva = cli_rva,
            .bodies_rva = bodies_rva,
            .metadata_rva = metadata_rva,
            .import_rva = import_rva,
            .ilt_rva = ilt_rva,
            .hint_name_rva = hint_name_rva,
            .dll_name_rva = dll_name_rva,
            .import_end = import_end,
            .operand_rva = operand_rva,
            .entry_rva = operand_rva - 2,
            .text = text,
            .rsrc = rsrc,
            .reloc = reloc,
            .section_count = section_count,
            .size_of_headers = size_of_headers,
            .size_of_image = next.virtual_address,
        };
    }
};

fn headersEnd(section_count: u16) u32 {
    const fixed: u32 = @sizeOf(DosHeader) + dos_stub.len + 4 + @sizeOf(CoffHeader) + size_of_optional_header;
    return fixed + @as(u32, section_count) * @sizeOf(SectionHeader);
}

const SectionLayout = struct {
    virtual_address: u32,
    virtual_size: u32,
    raw_offset: u32,

    fn rawSize(s: SectionLayout) u32 {
        return std.mem.alignForward(u32, s.virtual_size, file_alignment);
    }

    fn take(next: *SectionLayout, size: u32) SectionLayout {
        const taken: SectionLayout = .{
            .virtual_address = next.virtual_address,
            .virtual_size = size,
            .raw_offset = next.raw_offset,
        };
        next.virtual_address = std.mem.alignForward(u32, next.virtual_address + size, section_alignment);
        next.raw_offset += taken.rawSize();
        return taken;
    }
};

fn write(w: *std.Io.Writer, parsed: *const Parsed) error{WriteFailed}!void {
    const l: Layout = .init(parsed);
    const bodies = parsed.regions.get(.bodies).items;
    const rsrc = parsed.regions.get(.rsrc).items;

    try w.writeAll(std.mem.asBytes(&dos_header));
    try w.writeAll(dos_stub);
    try w.writeAll("PE\x00\x00");

    try w.writeStruct(CoffHeader{
        .machine = machine_i386,
        .number_of_sections = l.section_count,
        .timestamp = parsed.timestamp,
        .pointer_to_symbol_table = 0,
        .number_of_symbols = 0,
        .size_of_optional_header = size_of_optional_header,
        .characteristics = coff_characteristics,
    }, .little);

    try w.writeInt(u16, optional_header_magic_pe32, .little);
    try w.writeInt(u8, 11, .little); // linker version, csc's value
    try w.writeInt(u8, 0, .little);
    try w.writeInt(u32, l.text.rawSize(), .little); // size of code
    try w.writeInt(u32, l.rsrc.rawSize() + l.reloc.rawSize(), .little); // size of initialized data
    try w.writeInt(u32, 0, .little); // size of uninitialized data
    try w.writeInt(u32, l.entry_rva, .little);
    try w.writeInt(u32, l.text.virtual_address, .little); // base of code
    try w.writeInt(u32, l.rsrc.virtual_address, .little); // base of data

    try w.writeInt(u32, image_base, .little);
    try w.writeInt(u32, section_alignment, .little);
    try w.writeInt(u32, file_alignment, .little);
    try w.writeInt(u16, 4, .little); // os version
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little); // image version
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 4, .little); // subsystem version
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 0, .little); // win32 version value
    try w.writeInt(u32, l.size_of_image, .little);
    try w.writeInt(u32, l.size_of_headers, .little);
    try w.writeInt(u32, 0, .little); // checksum
    try w.writeInt(u16, subsystem_windows_cui, .little);
    try w.writeInt(u16, dll_characteristics, .little);
    try w.writeInt(u32, 0x100000, .little); // stack reserve
    try w.writeInt(u32, 0x1000, .little); // stack commit
    try w.writeInt(u32, 0x100000, .little); // heap reserve
    try w.writeInt(u32, 0x1000, .little); // heap commit
    try w.writeInt(u32, 0, .little); // loader flags
    try w.writeInt(u32, number_of_rva_and_sizes, .little);

    for (0..number_of_rva_and_sizes) |i| {
        const rva: u32, const size: u32 = switch (i) {
            directory_import => .{ l.import_rva, l.import_end - l.import_rva },
            directory_resource => .{ l.rsrc.virtual_address, l.rsrc.virtual_size },
            directory_base_relocation => .{ l.reloc.virtual_address, l.reloc.virtual_size },
            directory_iat => .{ l.iat_rva, 8 },
            directory_cli_header => .{ l.cli_rva, @sizeOf(CliHeader) },
            else => .{ 0, 0 },
        };
        try w.writeInt(u32, if (size == 0) 0 else rva, .little);
        try w.writeInt(u32, size, .little);
    }

    try writeSectionHeader(w, ".text", l.text, 0x60000020);
    if (l.rsrc.virtual_size > 0) try writeSectionHeader(w, ".rsrc", l.rsrc, 0x40000040);
    try writeSectionHeader(w, ".reloc", l.reloc, 0x42000040);
    try w.splatByteAll(0, l.size_of_headers - headersEnd(l.section_count));

    // .text: iat
    try w.writeInt(u32, l.hint_name_rva, .little);
    try w.writeInt(u32, 0, .little);
    // .text: cli header
    try w.writeStruct(CliHeader{
        .cb = @sizeOf(CliHeader),
        .major_runtime_version = 2,
        .minor_runtime_version = 5,
        .metadata_rva = l.metadata_rva,
        .metadata_size = metadataSize(parsed),
        .flags = cli_flags_il_only,
        .entry_point_token = 0,
        .resources = @splat(0),
        .strong_name_signature = @splat(0),
        .code_manager_table = @splat(0),
        .vtable_fixups = @splat(0),
        .export_address_table_jumps = @splat(0),
        .managed_native_header = @splat(0),
    }, .little);
    try w.writeAll(bodies);

    // metadata root
    try w.writeAll("BSJB");
    try w.writeInt(u16, 1, .little); // major version
    try w.writeInt(u16, 1, .little); // minor version
    try w.writeInt(u32, 0, .little); // reserved
    try w.writeInt(u32, metadata_version.len, .little);
    try w.writeAll(metadata_version);
    try w.writeInt(u16, 0, .little); // flags
    try w.writeInt(u16, streams.len, .little);
    var stream_offset = metadataRootSize();
    for (streams) |s| {
        try w.writeInt(u32, stream_offset, .little);
        try w.writeInt(u32, streamSize(parsed, s[0]), .little);
        try w.writeAll(s[1]);
        try w.splatByteAll(0, std.mem.alignForward(u32, @intCast(s[1].len + 1), 4) - s[1].len);
        stream_offset += streamSize(parsed, s[0]);
    }
    for (streams) |s| {
        const content = parsed.regions.get(s[0]).items;
        try w.writeAll(content);
        try w.splatByteAll(0, streamSize(parsed, s[0]) - content.len);
    }

    // .text: import directory, one entry then a null entry
    try w.writeInt(u32, l.ilt_rva, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, l.dll_name_rva, .little);
    try w.writeInt(u32, l.iat_rva, .little);
    try w.splatByteAll(0, 20);
    // .text: import lookup table
    try w.writeInt(u32, l.hint_name_rva, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeAll(import_hint_name);
    try w.writeAll(import_dll_name);
    // .text: entry stub, jmp through the iat
    try w.splatByteAll(0, l.entry_rva - l.import_end);
    try w.writeAll("\xff\x25");
    try w.writeInt(u32, image_base + l.iat_rva, .little);
    try w.splatByteAll(0, l.text.rawSize() - l.text.virtual_size);

    if (parsed.version) |v| {
        try writeRsrc(w, v, l.rsrc.virtual_address);
        try w.splatByteAll(0, l.rsrc.rawSize() - l.rsrc.virtual_size);
    } else if (rsrc.len > 0) {
        try w.writeAll(rsrc);
        try w.splatByteAll(0, l.rsrc.rawSize() - l.rsrc.virtual_size);
    }

    // .reloc: one HIGHLOW fixup for the entry stub's operand, plus a pad entry
    try w.writeInt(u32, l.operand_rva & ~@as(u32, 0xfff), .little);
    try w.writeInt(u32, 12, .little);
    try w.writeInt(u16, 0x3000 | @as(u16, @intCast(l.operand_rva & 0xfff)), .little);
    try w.writeInt(u16, 0, .little);
    try w.splatByteAll(0, l.reloc.rawSize() - l.reloc.virtual_size);

    try w.flush();
}

// The version resource csc emits by default: a three-level directory (type 16 = RT_VERSION,
// id 1, language 0) over one VS_VERSION_INFO whose every value derives from the file name
// and the version number.
fn align4(n: u32) u32 {
    return std.mem.alignForward(u32, n, 4);
}

fn verHeaderSize(key: []const u8) u32 {
    return align4(6 + (@as(u32, @intCast(key.len)) + 1) * 2);
}

fn verStringSize(key: []const u8, value: []const u8) u32 {
    return align4(verHeaderSize(key) + (@as(u32, @intCast(value.len)) + 1) * 2);
}

const VerStrings = struct {
    entries: [7]struct { []const u8, []const u8 },

    fn init(v: Version) VerStrings {
        return .{ .entries = .{
            .{ "FileDescription", " " },
            .{ "FileVersion", v.number },
            .{ "InternalName", v.file_name },
            .{ "LegalCopyright", " " },
            .{ "OriginalFilename", v.file_name },
            .{ "ProductVersion", v.number },
            .{ "Assembly Version", v.number },
        } };
    }
};

fn versionInfoSize(v: Version) u32 {
    var string_table = verHeaderSize("000004b0");
    for (VerStrings.init(v).entries) |e| string_table += verStringSize(e[0], e[1]);
    const string_file_info = verHeaderSize("StringFileInfo") + string_table;
    const translation = verHeaderSize("Translation") + 4;
    const var_file_info = verHeaderSize("VarFileInfo") + translation;
    return verHeaderSize("VS_VERSION_INFO") + 52 + var_file_info + string_file_info;
}

const rsrc_directory_size = 3 * (16 + 8) + 16;

fn rsrcSize(v: Version) u32 {
    return std.mem.alignForward(u32, rsrc_directory_size + versionInfoSize(v), 8);
}

fn writeUtf16(w: *std.Io.Writer, text: []const u8) error{WriteFailed}!void {
    for (text) |c| try w.writeInt(u16, c, .little);
}

fn writeVerHeader(
    w: *std.Io.Writer,
    length: u32,
    value_length: u32,
    kind: u16,
    key: []const u8,
) error{WriteFailed}!void {
    try w.writeInt(u16, @intCast(length), .little);
    try w.writeInt(u16, @intCast(value_length), .little);
    try w.writeInt(u16, kind, .little);
    try writeUtf16(w, key);
    try w.writeInt(u16, 0, .little);
    try w.splatByteAll(0, verHeaderSize(key) - (6 + (key.len + 1) * 2));
}

fn parseVersionPart(text: *[]const u8) u16 {
    const end = std.mem.indexOfScalar(u8, text.*, '.') orelse text.len;
    const part = std.fmt.parseInt(u16, text.*[0..end], 10) catch |err| errExit(
        "bad version number ({t})",
        .{err},
    );
    text.* = if (end == text.len) "" else text.*[end + 1 ..];
    return part;
}

fn writeRsrc(w: *std.Io.Writer, v: Version, rsrc_rva: u32) error{WriteFailed}!void {
    const info_size = versionInfoSize(v);

    // three directory levels, one entry each
    for ([3]struct { u32, u32 }{
        .{ 16, 0x80000000 | 0x18 },
        .{ 1, 0x80000000 | 0x30 },
        .{ 0, 0x48 },
    }) |entry| {
        try w.writeInt(u32, 0, .little); // characteristics
        try w.writeInt(u32, 0, .little); // timestamp
        try w.writeInt(u16, 0, .little); // major version
        try w.writeInt(u16, 0, .little); // minor version
        try w.writeInt(u16, 0, .little); // named entries
        try w.writeInt(u16, 1, .little); // id entries
        try w.writeInt(u32, entry[0], .little);
        try w.writeInt(u32, entry[1], .little);
    }
    try w.writeInt(u32, rsrc_rva + rsrc_directory_size, .little);
    try w.writeInt(u32, info_size, .little);
    try w.writeInt(u32, 0, .little); // code page
    try w.writeInt(u32, 0, .little); // reserved

    var number = v.number;
    const major = parseVersionPart(&number);
    const minor = parseVersionPart(&number);
    const build = parseVersionPart(&number);
    const revision = parseVersionPart(&number);
    const version_ms = @as(u32, major) << 16 | minor;
    const version_ls = @as(u32, build) << 16 | revision;

    try writeVerHeader(w, info_size, 52, 0, "VS_VERSION_INFO");
    try w.writeInt(u32, 0xfeef04bd, .little); // signature
    try w.writeInt(u32, 0x00010000, .little); // struct version
    try w.writeInt(u32, version_ms, .little);
    try w.writeInt(u32, version_ls, .little);
    try w.writeInt(u32, version_ms, .little); // product version
    try w.writeInt(u32, version_ls, .little);
    try w.writeInt(u32, 0x3f, .little); // file flags mask
    try w.writeInt(u32, 0, .little); // file flags
    try w.writeInt(u32, 4, .little); // VOS__WINDOWS32
    try w.writeInt(u32, 2, .little); // VFT_DLL
    try w.writeInt(u32, 0, .little); // subtype
    try w.writeInt(u32, 0, .little); // date
    try w.writeInt(u32, 0, .little);

    const translation = verHeaderSize("Translation") + 4;
    try writeVerHeader(w, verHeaderSize("VarFileInfo") + translation, 0, 1, "VarFileInfo");
    try writeVerHeader(w, translation, 4, 0, "Translation");
    try w.writeInt(u16, 0, .little); // language neutral
    try w.writeInt(u16, 0x04b0, .little); // unicode code page

    var string_table = verHeaderSize("000004b0");
    const strings: VerStrings = .init(v);
    for (strings.entries) |e| string_table += verStringSize(e[0], e[1]);
    try writeVerHeader(w, verHeaderSize("StringFileInfo") + string_table, 0, 1, "StringFileInfo");
    try writeVerHeader(w, string_table, 0, 1, "000004b0");
    for (strings.entries) |e| {
        const size = verStringSize(e[0], e[1]);
        try writeVerHeader(w, size, @intCast(e[1].len + 1), 1, e[0]);
        try writeUtf16(w, e[1]);
        try w.writeInt(u16, 0, .little);
        try w.splatByteAll(0, size - (verHeaderSize(e[0]) + (e[1].len + 1) * 2));
    }

    try w.splatByteAll(0, rsrcSize(v) - rsrc_directory_size - info_size);
}

fn writeSectionHeader(
    w: *std.Io.Writer,
    name: []const u8,
    l: SectionLayout,
    characteristics: u32,
) error{WriteFailed}!void {
    var header: SectionHeader = .{
        .name = @splat(0),
        .virtual_size = l.virtual_size,
        .virtual_address = l.virtual_address,
        .size_of_raw_data = l.rawSize(),
        .pointer_to_raw_data = l.raw_offset,
        .pointer_to_relocations = 0,
        .pointer_to_line_numbers = 0,
        .number_of_relocations = 0,
        .number_of_line_numbers = 0,
        .characteristics = characteristics,
    };
    @memcpy(header.name[0..name.len], name);
    try w.writeStruct(header, .little);
}

const DosHeader = extern struct {
    e_magic: [2]u8,
    e_cblp: u16,
    e_cp: u16,
    e_crlc: u16,
    e_cparhdr: u16,
    e_minalloc: u16,
    e_maxalloc: u16,
    e_ss: u16,
    e_sp: u16,
    e_csum: u16,
    e_ip: u16,
    e_cs: u16,
    e_lfarlc: u16,
    e_ovno: u16,
    e_res: [4]u16,
    e_oemid: u16,
    e_oeminfo: u16,
    e_res2: [10]u16,
    e_lfanew: u32,
};

const CoffHeader = extern struct {
    machine: u16,
    number_of_sections: u16,
    timestamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

const SectionHeader = extern struct {
    name: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32,
    pointer_to_line_numbers: u32,
    number_of_relocations: u16,
    number_of_line_numbers: u16,
    characteristics: u32,
};

const dos_stub =
    "\x0e\x1f\xba\x0e\x00\xb4\x09\xcd\x21\xb8\x01\x4c\xcd\x21" ++
    "This program cannot be run in DOS mode.\r\r\n$" ++
    "\x00" ** 7;

const dos_header: DosHeader = .{
    .e_magic = "MZ".*,
    .e_cblp = 0x90,
    .e_cp = 3,
    .e_crlc = 0,
    .e_cparhdr = 4,
    .e_minalloc = 0,
    .e_maxalloc = 0xffff,
    .e_ss = 0,
    .e_sp = 0xb8,
    .e_csum = 0,
    .e_ip = 0,
    .e_cs = 0,
    .e_lfarlc = 0x40,
    .e_ovno = 0,
    .e_res = @splat(0),
    .e_oemid = 0,
    .e_oeminfo = 0,
    .e_res2 = @splat(0),
    .e_lfanew = @sizeOf(DosHeader) + dos_stub.len,
};

fn splitDirective(line: []const u8) struct { []const u8, []const u8 } {
    const end = std.mem.indexOfAny(u8, line, " \t") orelse return .{ line, "" };
    return .{ line[0..end], std.mem.trim(u8, line[end..], " \t") };
}

fn nextArg(rest: *[]const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    const end = std.mem.indexOfAny(u8, rest.*, " \t") orelse rest.len;
    const a = rest.*[0..end];
    rest.* = std.mem.trimLeft(u8, rest.*[end..], " \t");
    return a;
}

fn requireArg(path: []const u8, lineno: u32, rest: *[]const u8) []const u8 {
    return nextArg(rest) orelse errExit("{s}:{}: missing argument", .{ path, lineno });
}

fn parseInt(path: []const u8, lineno: u32, text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 0) catch |err| errExit(
        "{s}:{}: '{s}' is not a number ({t})",
        .{ path, lineno, text, err },
    );
}

fn parseGuid(path: []const u8, lineno: u32, text: []const u8) [16]u8 {
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') errExit(
        "{s}:{}: '{s}' is not a guid (want XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX)",
        .{ path, lineno, text },
    );
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        digits[count] = std.fmt.charToDigit(c, 16) catch errExit(
            "{s}:{}: bad guid digit '{c}'",
            .{ path, lineno, c },
        );
        count += 1;
    }
    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = digits[i * 2] << 4 | digits[i * 2 + 1];
    // the first three groups are little-endian fields
    var guid: [16]u8 = undefined;
    guid[0] = bytes[3];
    guid[1] = bytes[2];
    guid[2] = bytes[1];
    guid[3] = bytes[0];
    guid[4] = bytes[5];
    guid[5] = bytes[4];
    guid[6] = bytes[7];
    guid[7] = bytes[6];
    @memcpy(guid[8..], bytes[8..]);
    return guid;
}

fn parseQuoted(path: []const u8, lineno: u32, text: []const u8) []const u8 {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') errExit(
        "{s}:{}: expected a quoted string, got '{s}'",
        .{ path, lineno, text },
    );
    const value = text[1 .. text.len - 1];
    if (std.mem.indexOfAny(u8, value, "\"\\") != null) errExit(
        "{s}:{}: string escapes are not implemented",
        .{ path, lineno },
    );
    return value;
}

fn appendHex(
    arena: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    lineno: u32,
    digits: []const u8,
) void {
    var high: ?u8 = null;
    for (digits) |c| {
        if (c == ' ' or c == '\t') continue;
        const digit = std.fmt.charToDigit(c, 16) catch errExit(
            "{s}:{}: bad hex digit '{c}'",
            .{ path, lineno, c },
        );
        if (high) |hi| {
            list.append(arena, hi << 4 | digit) catch |err| errExit("{t}", .{err});
            high = null;
        } else high = digit;
    }
    if (high != null) errExit("{s}:{}: odd number of hex digits", .{ path, lineno });
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const metadata = @import("metadata.zig");
