const UnityVersion = @This();

major: u16,
minor: u16,
build: u16,
revision: u16,

pub fn atLeast(v: UnityVersion, major: u16, minor: u16) bool {
    if (v.major != major) return v.major > major;
    return v.minor >= minor;
}

pub fn format(v: UnityVersion, writer: *std.Io.Writer) error{WriteFailed}!void {
    try writer.print("{}.{}.{}.{}", .{ v.major, v.minor, v.build, v.revision });
}

pub const ReadError = error{ NoVersionInfo, VersionInfoTooBig };

pub fn fromLoadedModule(module: dynlib.Module) ReadError!UnityVersion {
    if (builtin.os.tag == .windows) {
        var path_buf: [win32.MAX_PATH:0]u16 = undefined;
        const path_len = win32.GetModuleFileNameW(module, &path_buf, path_buf.len);
        if (path_len == 0) {
            std.log.err("GetModuleFileName(UnityPlayer.dll) failed, error={f}", .{win32.GetLastError()});
            return error.NoVersionInfo;
        }
        // GetModuleFileNameW returns nSize on truncation (and may not null-terminate), which would
        // leave us reading a mangled path; fail at the real cause instead.
        if (path_len >= path_buf.len) {
            std.log.err("UnityPlayer.dll path is longer than {} chars", .{path_buf.len});
            return error.NoVersionInfo;
        }
        path_buf[path_len] = 0;
        return fromFile(path_buf[0..path_len :0]);
    } else @panic("todo: unity version off-windows");
}

// Reads the Unity version from a UnityPlayer.dll on disk, without loading it.
pub fn fromFile(path: [:0]const u16) ReadError!UnityVersion {
    if (builtin.os.tag == .windows) {
        const size = win32.GetFileVersionInfoSizeW(path, null);
        if (size == 0) {
            std.log.err("GetFileVersionInfoSize '{f}' failed, error={f}", .{ std.unicode.fmtUtf16Le(path), win32.GetLastError() });
            return error.NoVersionInfo;
        }
        var info_buf: [4096]u8 = undefined;
        if (size > info_buf.len) {
            std.log.err("version info for '{f}' is {} bytes, too big for our {} byte buffer", .{ std.unicode.fmtUtf16Le(path), size, info_buf.len });
            return error.VersionInfoTooBig;
        }
        if (0 == win32.GetFileVersionInfoW(path, 0, size, &info_buf)) {
            std.log.err("GetFileVersionInfo '{f}' failed, error={f}", .{ std.unicode.fmtUtf16Le(path), win32.GetLastError() });
            return error.NoVersionInfo;
        }
        var fixed: ?*anyopaque = null;
        var fixed_len: u32 = 0;
        if (0 == win32.VerQueryValueW(&info_buf, win32.L("\\"), &fixed, &fixed_len)) {
            std.log.err("VerQueryValue '{f}' has no fixed version info", .{std.unicode.fmtUtf16Le(path)});
            return error.NoVersionInfo;
        }
        if (fixed_len < @sizeOf(win32.VS_FIXEDFILEINFO)) {
            std.log.err("VerQueryValue '{f}' gave {} bytes, expected at least {}", .{ std.unicode.fmtUtf16Le(path), fixed_len, @sizeOf(win32.VS_FIXEDFILEINFO) });
            return error.NoVersionInfo;
        }
        const info: *const win32.VS_FIXEDFILEINFO = @ptrCast(@alignCast(fixed.?));
        return .{
            .major = @intCast(info.dwFileVersionMS >> 16),
            .minor = @intCast(info.dwFileVersionMS & 0xffff),
            .build = @intCast(info.dwFileVersionLS >> 16),
            .revision = @intCast(info.dwFileVersionLS & 0xffff),
        };
    } else @panic("todo: unity version off-windows");
}

const builtin = @import("builtin");
const std = @import("std");
const dynlib = @import("dynlib.zig");
const win32 = @import("win32").everything;
