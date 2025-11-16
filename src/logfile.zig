pub const global = struct {
    pub var write_log_mutex: Mutex = .{};

    var get_log_file_mutex: Mutex = .{};
    var cached: ?std.fs.File = null;

    pub fn get(open_error: *?win32.WIN32_ERROR) std.fs.File {
        std.debug.assert(open_error.* == null);
        get_log_file_mutex.lock();
        defer get_log_file_mutex.unlock();
        if (cached == null) {
            cached = blk: {
                if (builtin.os.tag == .windows) {
                    const handle = win32.CreateFileW(
                        win32.L("C:\\temp\\mutiny.log"),
                        .{ .FILE_APPEND_DATA = 1 }, // all writes append to end of file
                        .{ .READ = 1 },
                        null,
                        .CREATE_ALWAYS, // always create and truncate the file
                        .{ .FILE_ATTRIBUTE_NORMAL = 1 },
                        null,
                    );
                    if (handle != win32.INVALID_HANDLE_VALUE) break :blk .{ .handle = handle };
                    open_error.* = win32.GetLastError();
                } else @compileError("todo");
                break :blk std.fs.File.stderr();
            };
        }
        return cached.?;
    }
};

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const Mutex = @import("Mutex.zig");
