// Reports an exception nothing caught, then lets the process die with its code.
//
// Windows is the one platform where this is known to be needed. A game runtime (mono, il2cpp) reports some failures by throwing a
// C++ exception, and on Windows a C++ throw is an SEH exception with code 0xE06D7363. If nothing
// catches it, Windows ends the process with that code as the exit code and prints nothing.
//
// Zig's default handlers do not cover it. The panic handler only runs for a Zig panic, and the
// handler std installs (debug.zig, handleSegfaultWindows) only reports access violations,
// illegal instructions, misaligned accesses and stack overflows. For every other code it returns
// EXCEPTION_CONTINUE_SEARCH without calling the panic handler. That handler is a vectored one,
// which sees every exception before anything has a chance to catch it, so it could not report
// C++ throws anyway: the runtimes throw and catch them internally all the time. The unhandled
// exception filter runs only once no handler has taken the exception, so it fires only when the
// process is about to die.
//
// Other platforms have not been checked. There an uncaught C++ exception should call
// std::terminate, whose default handler in libstdc++ and libc++ prints the thrown type before
// abort(), but nobody has run a game runtime there to see whether that holds.
pub fn install() void {
    if (builtin.os.tag != .windows) return;
    if (builtin.cpu.arch != .x86_64) @compileError("todo: the MSVC C++ exception layout for this arch (x86 has absolute pointers and 3 parameters)");
    if (win32.SetUnhandledExceptionFilter(filter)) |previous| std.debug.panic(
        "an unhandled exception filter was already installed (0x{x})",
        .{@intFromPtr(previous)},
    );
}

const exception_continue_search: i32 = 0;
const exception_execute_handler: i32 = 1;

const msvc_cpp_exception: u32 = 0xE06D7363;
const msvc_cpp_magics = [_]usize{ 0x19930520, 0x19930521, 0x19930522 };

fn filter(maybe_info: ?*win32.EXCEPTION_POINTERS) callconv(.winapi) i32 {
    const info: *std.os.windows.EXCEPTION_POINTERS = @ptrCast(@alignCast(maybe_info orelse return exception_continue_search));
    // A Debug build's std.process.abort raises a breakpoint after a panic was already reported.
    if (info.ExceptionRecord.ExceptionCode == @intFromEnum(win32.EXCEPTION_BREAKPOINT)) return exception_continue_search;
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();
    report(stderr, info.ExceptionRecord) catch return exception_continue_search;
    std.debug.dumpStackTraceFromBase(info.ContextRecord, stderr);
    return exception_execute_handler;
}

fn report(w: *std.Io.Writer, record: *const std.os.windows.EXCEPTION_RECORD) error{WriteFailed}!void {
    const code: u32 = @bitCast(record.ExceptionCode);
    try w.print("unhandled exception 0x{X:0>8}", .{code});
    if (code == msvc_cpp_exception) try w.writeAll(" (a C++ throw)");
    const address = @intFromPtr(record.ExceptionAddress);
    try w.print(" at 0x{x}", .{address});
    // Flushed before anything that could fail, so the code and address always reach stderr.
    try w.flush();
    try writeModule(w, address);
    try w.writeAll("\n");
    if (code == msvc_cpp_exception) try writeCppType(w, record);
    try w.flush();
}

fn writeModule(w: *std.Io.Writer, address: usize) error{WriteFailed}!void {
    var module: ?win32.HINSTANCE = null;
    if (0 == win32.GetModuleHandleExW(
        win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(address),
        &module,
    )) return w.print(" ({f})", .{Error.initWin32("GetModuleHandleExW", win32.GetLastError())});
    const offset = address - @intFromPtr(module.?);
    // MAX_PATH, not PATH_MAX_WIDE: this runs on the faulting thread, whose stack may be small or
    // nearly exhausted, and only the basename is printed.
    var path_buf: [win32.MAX_PATH:0]u16 = undefined;
    const len = win32.GetModuleFileNameW(module, &path_buf, path_buf.len + 1);
    if (len == 0) return w.print(" (+0x{x}, {f})", .{ offset, Error.initWin32("GetModuleFileNameW", win32.GetLastError()) });
    if (len == path_buf.len + 1) return w.print(" (+0x{x}, the module path is longer than MAX_PATH)", .{offset});
    const path = path_buf[0..len];
    const name = path[if (std.mem.lastIndexOfScalar(u16, path, '\\')) |i| i + 1 else 0..];
    try w.print(" ({f}+0x{x})", .{ std.unicode.fmtUtf16Le(name), offset });
}

fn writeCppType(w: *std.Io.Writer, record: *const std.os.windows.EXCEPTION_RECORD) error{WriteFailed}!void {
    if (record.NumberParameters != 4) return w.print("  {} exception parameters, expected 4\n", .{record.NumberParameters});
    const params = record.ExceptionInformation;
    if (std.mem.indexOfScalar(usize, &msvc_cpp_magics, params[0]) == null) return w.print("  unknown C++ exception magic 0x{x}\n", .{params[0]});
    if (params[2] == 0) return w.writeAll("  a rethrow with no type information\n");
    const throw_info: *const ThrowInfo = @ptrFromInt(params[2]);
    const image_base = params[3];
    const types: *const CatchableTypeArray = @ptrFromInt(rva(image_base, throw_info.catchable_type_array));
    if (types.count <= 0) return w.writeAll("  the thrown type has no catchable types\n");
    const catchable: *const CatchableType = @ptrFromInt(rva(image_base, types.types[0]));
    const descriptor: *const TypeDescriptor = @ptrFromInt(rva(image_base, catchable.type));
    const name: [*:0]const u8 = @ptrCast(&descriptor.name);
    try w.print("  thrown type {s}, object at 0x{x}\n", .{ std.mem.span(name), params[1] });
}

fn rva(image_base: usize, offset: i32) usize {
    return image_base + @as(u32, @bitCast(offset));
}

const ThrowInfo = extern struct {
    attributes: u32,
    unwind: i32,
    forward_compat: i32,
    catchable_type_array: i32,
};

const CatchableTypeArray = extern struct {
    count: i32,
    types: [1]i32,
};

const CatchableType = extern struct {
    properties: u32,
    type: i32,
};

const TypeDescriptor = extern struct {
    vtable: ?*const anyopaque,
    spare: ?*anyopaque,
    name: [0:0]u8,
};

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const Error = @import("Error.zig");
