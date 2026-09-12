pub fn findAppId(scratch: std.mem.Allocator, exe: []const u16) !?u32 {
    const path = try std.unicode.utf16LeToUtf8Alloc(scratch, exe);
    defer scratch.free(path);

    var steamapps_end: usize = 0;
    var installdir: []const u8 = "";
    {
        var it = std.mem.splitAny(u8, path, "\\/");
        var offset: usize = 0;
        var after_steamapps: ?usize = null;
        var after_common: ?usize = null;
        while (it.next()) |component| : (offset += component.len + 1) {
            if (after_common != null) {
                installdir = component;
                break;
            }
            if (after_steamapps != null) {
                if (!std.ascii.eqlIgnoreCase(component, "common")) return null;
                after_common = offset;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(component, "steamapps")) {
                after_steamapps = offset;
                steamapps_end = offset + component.len;
            }
        }
        if (installdir.len == 0) return null;
    }

    var dir = try std.fs.openDirAbsolute(path[0..steamapps_end], .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "appmanifest_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".acf")) continue;
        const text = try dir.readFileAlloc(scratch, entry.name, 1024 * 1024);
        defer scratch.free(text);
        const manifest_installdir = acfValue(text, "installdir") orelse continue;
        if (!std.ascii.eqlIgnoreCase(manifest_installdir, installdir)) continue;
        const appid = acfValue(text, "appid") orelse return error.ManifestHasNoAppId;
        return std.fmt.parseInt(u32, appid, 10) catch return error.ManifestAppIdInvalid;
    }
    return null;
}

fn acfValue(text: []const u8, key: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, key)) |found| {
        search = found + key.len;
        if (found == 0 or text[found - 1] != '"') continue;
        if (search >= text.len or text[search] != '"') continue;
        var i = search + 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len or text[i] != '"') continue;
        const value_start = i + 1;
        const value_end = std.mem.indexOfScalarPos(u8, text, value_start, '"') orelse return null;
        return text[value_start..value_end];
    }
    return null;
}

test acfValue {
    const acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"3527290\"\n\t\"name\"\t\t\"PEAK\"\n\t\"installdir\"\t\t\"PEAK\"\n}\n";
    try std.testing.expectEqualStrings("3527290", acfValue(acf, "appid").?);
    try std.testing.expectEqualStrings("PEAK", acfValue(acf, "installdir").?);
    try std.testing.expect(acfValue(acf, "missing") == null);
}

const std = @import("std");
