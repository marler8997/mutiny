//! An icon rendered from an svg that lives in source control so the build needs no
//! renderer. The step checks at build time whether the ico is current: a tEXt chunk in its
//! PNG frame carries the hash of the svg and the exporter script that produced it, and it
//! does nothing when they match. When they have changed it runs the exporter, which
//! rasterises the svg through a headless browser, stamps the hash in and writes the ico
//! back into the source tree to be committed; on a host without the browser a stale ico
//! fails the step instead.
const UpdateIco = @This();

step: std.Build.Step,
generated: std.Build.GeneratedFile,
svg_path: []const u8,
script_path: []const u8,
out_path: []const u8,

const text_keyword = "mutiny-source";

pub fn create(b: *std.Build, paths: struct {
    svg_path: []const u8,
    script_path: []const u8,
    out_path: []const u8,
}) *UpdateIco {
    const self = b.allocator.create(UpdateIco) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("update {s}", .{paths.out_path}),
            .owner = b,
            .makeFn = make,
        }),
        .generated = .{ .step = &self.step, .path = b.pathFromRoot(paths.out_path) },
        .svg_path = b.dupePath(paths.svg_path),
        .script_path = b.dupePath(paths.script_path),
        .out_path = b.dupePath(paths.out_path),
    };
    return self;
}

// a generated path, so anything that uses the ico depends on the step that updates it
pub fn path(self: *UpdateIco) std.Build.LazyPath {
    return .{ .generated = .{ .file = &self.generated } };
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    _ = options;
    const self: *UpdateIco = @fieldParentPtr("step", step);
    const b = step.owner;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        try hashFile(step, &hasher, b.pathFromRoot(self.svg_path));
        try hashFile(step, &hasher, b.pathFromRoot(self.script_path));
        hasher.final(&digest);
    }
    const want = std.fmt.bytesToHex(digest[0..16], .lower);

    if (b.build_root.handle.readFileAlloc(
        b.allocator,
        self.out_path,
        std.math.maxInt(usize),
    )) |image| {
        if (try storedHash(step, image)) |have| if (std.mem.eql(u8, have, &want)) {
            step.result_cached = true;
            return;
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return step.fail("read {s} failed with {t}", .{ self.out_path, err }),
    }

    if (@import("builtin").os.tag != .windows) return step.fail(
        "{s} changed, but rendering {s} needs a browser; run 'zig build' on Windows and commit the updated ico",
        .{ self.svg_path, self.out_path },
    );

    const raw_path = b.pathJoin(&.{ b.makeTempPath(), std.fs.path.basename(self.out_path) });
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            b.pathFromRoot(self.script_path),
            "-Svg",
            b.pathFromRoot(self.svg_path),
            "-Ico",
            raw_path,
        },
    }) catch |err| return step.fail("running {s} failed with {t}", .{ self.script_path, err });
    switch (result.term) {
        .Exited => |code| if (code != 0) return step.fail(
            "{s} failed with exit code {}:\n{s}{s}",
            .{ self.script_path, code, result.stdout, result.stderr },
        ),
        else => return step.fail("{s} did not exit normally", .{self.script_path}),
    }

    const raw = b.build_root.handle.readFileAlloc(
        b.allocator,
        raw_path,
        std.math.maxInt(usize),
    ) catch |err| return step.fail("read {s} failed with {t}", .{ raw_path, err });
    const stamped = try stamp(step, raw, &want);
    b.build_root.handle.writeFile(
        .{ .sub_path = self.out_path, .data = stamped },
    ) catch |err| return step.fail("write {s} failed with {t}", .{ self.out_path, err });
}

fn hashFile(step: *std.Build.Step, hasher: *std.crypto.hash.sha2.Sha256, file_path: []const u8) !void {
    const b = step.owner;
    const content = std.fs.cwd().readFileAlloc(
        b.allocator,
        file_path,
        std.math.maxInt(usize),
    ) catch |err| return step.fail("read {s} failed with {t}", .{ file_path, err });
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, content.len, .little);
    hasher.update(&len);
    hasher.update(content);
}

const png_signature = "\x89PNG\r\n\x1a\n";
const ihdr_end = png_signature.len + 4 + 4 + 13 + 4;

const Entry = struct { index: usize, offset: u32, size: u32 };

// the directory entry of the one PNG frame, where the hash is kept
fn pngEntry(step: *std.Build.Step, image: []const u8) !Entry {
    if (image.len < 6) return step.fail("ico is truncated", .{});
    const count = std.mem.readInt(u16, image[4..6], .little);
    var found: ?Entry = null;
    for (0..count) |i| {
        const entry = 6 + i * 16;
        if (entry + 16 > image.len) return step.fail("ico directory is truncated", .{});
        const size = std.mem.readInt(u32, image[entry + 8 ..][0..4], .little);
        const offset = std.mem.readInt(u32, image[entry + 12 ..][0..4], .little);
        if (offset + size > image.len) return step.fail("ico frame {} runs past the end of the file", .{i});
        if (size >= ihdr_end and std.mem.eql(u8, image[offset..][0..png_signature.len], png_signature)) {
            if (found != null) return step.fail("ico has more than one PNG frame", .{});
            found = .{ .index = i, .offset = offset, .size = size };
        }
    }
    return found orelse step.fail("ico has no PNG frame to carry the source hash", .{});
}

fn storedHash(step: *std.Build.Step, image: []const u8) !?[]const u8 {
    const entry = try pngEntry(step, image);
    const png = image[entry.offset..][0..entry.size];
    var p: usize = png_signature.len;
    while (p + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[p..][0..4], .big);
        const kind = png[p + 4 ..][0..4];
        if (p + 12 + len > png.len) return step.fail("png chunk runs past the frame", .{});
        const data = png[p + 8 ..][0..len];
        if (std.mem.eql(u8, kind, "tEXt") and std.mem.startsWith(u8, data, text_keyword ++ "\x00")) {
            return data[text_keyword.len + 1 ..];
        }
        if (std.mem.eql(u8, kind, "IEND")) break;
        p += 12 + len;
    }
    return null;
}

// returns a copy of the ico with a tEXt chunk carrying the hash inserted after the PNG
// frame's IHDR, the directory adjusted for the frame growing
fn stamp(step: *std.Build.Step, image: []const u8, hash: []const u8) ![]u8 {
    const b = step.owner;
    const entry = try pngEntry(step, image);
    const text = b.fmt(text_keyword ++ "\x00{s}", .{hash});
    const chunk_len = 12 + text.len;
    const out = b.allocator.alloc(u8, image.len + chunk_len) catch @panic("OOM");

    const insert_at = entry.offset + ihdr_end;
    @memcpy(out[0..insert_at], image[0..insert_at]);
    var chunk = out[insert_at..][0..chunk_len];
    std.mem.writeInt(u32, chunk[0..4], @intCast(text.len), .big);
    @memcpy(chunk[4..8], "tEXt");
    @memcpy(chunk[8..][0..text.len], text);
    std.mem.writeInt(u32, chunk[8 + text.len ..][0..4], std.hash.Crc32.hash(chunk[4 .. 8 + text.len]), .big);
    @memcpy(out[insert_at + chunk_len ..], image[insert_at..]);

    const count = std.mem.readInt(u16, out[4..6], .little);
    for (0..count) |i| {
        const dir = 6 + i * 16;
        const size = out[dir + 8 ..][0..4];
        const offset = out[dir + 12 ..][0..4];
        if (i == entry.index) std.mem.writeInt(u32, size, @intCast(entry.size + chunk_len), .little);
        if (std.mem.readInt(u32, offset, .little) > entry.offset) {
            std.mem.writeInt(u32, offset, @intCast(std.mem.readInt(u32, offset, .little) + chunk_len), .little);
        }
    }
    return out;
}

const std = @import("std");
