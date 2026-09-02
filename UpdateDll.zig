//! A csc-built dll that lives in source control so the build needs no csc. The step checks
//! at build time whether the dll is current, its mvid carries the hash of the source that
//! built it (see purify below) and does nothing when it is. When the source has changed it
//! recompiles the dll, purifies it, and writes it back into the source tree to be
//! committed; that needs csc, so on other hosts a stale dll fails the step instead.
const UpdateDll = @This();

step: std.Build.Step,
generated: std.Build.GeneratedFile,
source_path: []const u8,
out_path: []const u8,

pub fn create(b: *std.Build, paths: struct {
    source_path: []const u8,
    out_path: []const u8,
}) *UpdateDll {
    const self = b.allocator.create(UpdateDll) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("update {s}", .{paths.out_path}),
            .owner = b,
            .makeFn = make,
        }),
        .generated = .{ .step = &self.step, .path = b.pathFromRoot(paths.out_path) },
        .source_path = b.dupePath(paths.source_path),
        .out_path = b.dupePath(paths.out_path),
    };
    return self;
}

// a generated path, so anything that uses the dll depends on the step that updates it
pub fn path(self: *UpdateDll) std.Build.LazyPath {
    return .{ .generated = .{ .file = &self.generated } };
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const self: *UpdateDll = @fieldParentPtr("step", step);
    const b = step.owner;

    const source = b.build_root.handle.readFileAlloc(
        b.allocator,
        self.source_path,
        std.math.maxInt(usize),
    ) catch |err| return step.fail("read {s} failed with {t}", .{ self.source_path, err });

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});

    if (b.build_root.handle.readFileAlloc(
        b.allocator,
        self.out_path,
        std.math.maxInt(usize),
    )) |image| {
        const mvid_offset = try locateMvid(step, image);
        if (std.mem.eql(u8, image[mvid_offset..][0..16], digest[0..16])) {
            step.result_cached = true;
            return;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return step.fail("read {s} failed with {t}", .{ self.out_path, err }),
    }

    if (@import("builtin").os.tag != .windows) return step.fail(
        "{s} changed, but rebuilding {s} needs csc; run 'zig build' on Windows and commit the updated dll",
        .{ self.source_path, self.out_path },
    );

    // csc names the assembly after the output file's basename, so compile to the real
    // name (in a temp dir) rather than something like raw.dll
    const raw_path = b.pathJoin(&.{ b.makeTempPath(), std.fs.path.basename(self.out_path) });
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{
            "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
            "/target:library",
            "/nologo",
            b.fmt("/out:{s}", .{raw_path}),
            b.pathFromRoot(self.source_path),
        },
    }) catch |err| return step.fail("running csc failed with {t}", .{err});
    switch (result.term) {
        .Exited => |code| if (code != 0) return step.fail(
            "csc failed with exit code {}:\n{s}{s}",
            .{ code, result.stdout, result.stderr },
        ),
        else => return step.fail("csc did not exit normally", .{}),
    }

    const image = b.build_root.handle.readFileAlloc(
        b.allocator,
        raw_path,
        std.math.maxInt(usize),
    ) catch |err| return step.fail("read {s} failed with {t}", .{ raw_path, err });

    try purify(step, image, &digest);
    b.build_root.handle.writeFile(
        .{ .sub_path = self.out_path, .data = image },
    ) catch |err| return step.fail("write {s} failed with {t}", .{ self.out_path, err });
}

fn purify(step: *std.Build.Step, image: []u8, input_hash: *const [32]u8) !void {
    const new_mvid = input_hash[0..16];

    const e_lfanew = try readInt(step, u32, image, 0x3c);
    std.mem.writeInt(u32, image[e_lfanew + 8 ..][0..4], 0, .little); // timestamp

    const mvid = image[try locateMvid(step, image)..][0..16];
    const old_text = guidText(mvid.*);
    const new_text = guidText(new_mvid.*);
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, image, search, &old_text)) |at| {
        @memcpy(image[at..][0..new_text.len], &new_text);
        search = at + new_text.len;
    }
    @memcpy(mvid, new_mvid);
}

// the file offset of the module's mvid, the one guid in the #GUID stream
fn locateMvid(step: *std.Build.Step, image: []const u8) !u32 {
    const e_lfanew = try readInt(step, u32, image, 0x3c);
    if (!std.mem.eql(u8, image[e_lfanew..][0..4], "PE\x00\x00")) {
        return step.fail("not a PE image", .{});
    }
    const optional_header = e_lfanew + 24;
    if (try readInt(step, u16, image, optional_header) != 0x10b) {
        return step.fail("only PE32 images are supported", .{});
    }
    const section_count = try readInt(step, u16, image, e_lfanew + 6);
    const sections = optional_header + try readInt(step, u16, image, e_lfanew + 20);
    const cli_rva = try readInt(step, u32, image, optional_header + 96 + 14 * 8);
    if (cli_rva == 0) return step.fail("no cli header", .{});
    const cli = try rvaToOffset(step, image, sections, section_count, cli_rva);
    const metadata_rva = try readInt(step, u32, image, cli + 8);
    const metadata = try rvaToOffset(step, image, sections, section_count, metadata_rva);
    if (!std.mem.eql(u8, image[metadata..][0..4], "BSJB")) {
        return step.fail("no metadata root at 0x{x}", .{metadata});
    }

    const version_len = try readInt(step, u32, image, metadata + 12);
    const stream_count = try readInt(step, u16, image, metadata + 16 + version_len + 2);
    var p = metadata + 16 + version_len + 4;
    for (0..stream_count) |_| {
        const offset = try readInt(step, u32, image, p);
        const size = try readInt(step, u32, image, p + 4);
        const name_end = std.mem.indexOfScalarPos(u8, image, p + 8, 0) orelse {
            return step.fail("unterminated stream name at 0x{x}", .{p + 8});
        };
        const name = image[p + 8 .. name_end];
        p = std.mem.alignForward(u32, @intCast(name_end + 1), 4);
        if (std.mem.eql(u8, name, "#GUID")) {
            if (size != 16) return step.fail(
                "expected one guid in the #GUID stream, got {} bytes",
                .{size},
            );
            return metadata + offset;
        }
    }
    return step.fail("no #GUID stream", .{});
}

fn guidText(guid: [16]u8) [36]u8 {
    var text: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{X:0>8}-{X:0>4}-{X:0>4}-{s}-{s}", .{
        std.mem.readInt(u32, guid[0..4], .little),
        std.mem.readInt(u16, guid[4..6], .little),
        std.mem.readInt(u16, guid[6..8], .little),
        &std.fmt.bytesToHex(guid[8..10].*, .upper),
        &std.fmt.bytesToHex(guid[10..16].*, .upper),
    }) catch unreachable;
    return text;
}

fn readInt(step: *std.Build.Step, comptime T: type, image: []const u8, offset: usize) !T {
    if (offset + @sizeOf(T) > image.len) {
        return step.fail("image truncated at 0x{x}", .{offset});
    }
    return std.mem.readInt(T, image[offset..][0..@sizeOf(T)], .little);
}

fn rvaToOffset(
    step: *std.Build.Step,
    image: []const u8,
    sections: u32,
    section_count: u16,
    rva: u32,
) !u32 {
    for (0..section_count) |i| {
        const header: u32 = @intCast(sections + i * 40);
        const virtual_size = try readInt(step, u32, image, header + 8);
        const virtual_address = try readInt(step, u32, image, header + 12);
        const raw_offset = try readInt(step, u32, image, header + 20);
        if (rva >= virtual_address and rva < virtual_address + virtual_size) {
            return raw_offset + (rva - virtual_address);
        }
    }
    return step.fail("rva 0x{x} is in no section", .{rva});
}

const std = @import("std");
