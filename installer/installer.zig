const Payload = struct {
    import: []const u8,
    dest: []const u8,
};

const payload = [_]Payload{
    .{ .import = "bin_mutiny_exe", .dest = "bin\\mutiny.exe" },
    .{ .import = "dll_Mutiny_dll", .dest = "dll\\Mutiny.dll" },
    .{ .import = "Mutiny_exe", .dest = "Mutiny.exe" },
    .{ .import = "mutiny_agent_md", .dest = "mutiny-agent.md" },
};

const gui_exe = "Mutiny.exe";
const gui_window_class = win32.L("MutinyMainWindow");
const setup_exe = "MutinySetup.exe";
const shortcut_name = "Mutiny.lnk";
const uninstall_key = win32.L("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Mutiny");
const mutex_name = win32.L("MutinyInstallRunning");
const hwnd_broadcast: win32.HWND = @ptrFromInt(0xffff);

const global = struct {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var log_file: ?std.fs.File = null;
    var log_path: []const u8 = "";
};

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const file = global.log_file orelse return;
    var buf: [1000]u8 = undefined;
    var writer = file.writerStreaming(&buf);
    writer.interface.print(comptime level.asText() ++ ": " ++ format ++ "\n", args) catch return;
    writer.interface.flush() catch return;
}

pub const panic = std.debug.FullPanic(panicFn);
fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    std.log.err("panic: {s}", .{msg});
    _ = messageBox(.{ .ICONHAND = 1 }, "Mutiny Setup", "{s}", .{msg});
    std.debug.defaultPanic(msg, ret_addr);
}

fn oom(e: error{OutOfMemory}) noreturn {
    std.debug.panic("{t}", .{e});
}

fn wide(utf8: []const u8) [:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(global.arena, utf8) catch |err| switch (err) {
        error.OutOfMemory => |e| oom(e),
        error.InvalidWtf8 => std.debug.panic("invalid WTF-8 '{s}'", .{utf8}),
    };
}

fn narrow(w: []const u16) []const u8 {
    return std.unicode.wtf16LeToWtf8Alloc(global.arena, w) catch |e| oom(e);
}

fn messageBox(style: win32.MESSAGEBOX_STYLE, title: [:0]const u8, comptime fmt: []const u8, args: anytype) win32.MESSAGEBOX_RESULT {
    const text = std.fmt.allocPrint(global.arena, fmt, args) catch |e| oom(e);
    return win32.MessageBoxW(null, wide(text), wide(title), style);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    const message = std.fmt.allocPrint(global.arena, fmt, args) catch |e| oom(e);
    const log_line = std.fmt.allocPrint(global.arena, "The log is {s}", .{global.log_path}) catch |e| oom(e);
    _ = dialog.show(.{
        .title = "Mutiny Setup failed",
        .lines = if (global.log_path.len == 0) &.{.{ .text = message }} else &.{ .{ .text = message }, .{ .text = log_line, .muted = true } },
        .buttons = &.{.{ .label = "Close", .style = .normal }},
    });
    win32.ExitProcess(1);
}

fn join(parts: []const []const u8) []const u8 {
    return std.fs.path.join(global.arena, parts) catch |e| oom(e);
}

pub fn main() void {
    {
        var awareness: win32.PROCESS_DPI_AWARENESS = undefined;
        const hr = win32.GetProcessDpiAwareness(null, &awareness);
        if (hr < 0) std.debug.panic("GetProcessDpiAwareness failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
        switch (awareness) {
            .PER_MONITOR_DPI_AWARE => {},
            else => |a| std.debug.panic("the process is {t}, the manifest should make it PER_MONITOR_DPI_AWARE", .{a}),
        }
    }

    const args = std.process.argsAlloc(global.arena) catch |err| std.debug.panic("reading the command line failed with {t}", .{err});
    var uninstall = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--uninstall")) {
            uninstall = true;
        } else {
            fail("unknown argument '{s}'", .{arg});
        }
    }

    const localappdata = std.process.getEnvVarOwned(global.arena, "LOCALAPPDATA") catch |err| fail("no LOCALAPPDATA environment variable ({t})", .{err});
    const install_dir = join(&.{ localappdata, "mutiny" });
    const self_exe = std.fs.selfExePathAlloc(global.arena) catch |err| fail("cannot find my own path ({t})", .{err});
    const temp = std.process.getEnvVarOwned(global.arena, "TEMP") catch |err| fail("no TEMP environment variable ({t})", .{err});

    if (uninstall) {
        openLog(join(&.{ temp, "mutiny-uninstall.log" }));
        runUninstall(install_dir, self_exe, temp);
    } else {
        openLog(join(&.{ temp, "mutiny-install.log" }));
        runInstall(install_dir, self_exe);
    }
}

fn openLog(path: []const u8) void {
    global.log_path = path;
    global.log_file = std.fs.cwd().createFile(path, .{}) catch |err| {
        global.log_path = "";
        fail("cannot create the log '{s}' ({t})", .{ path, err });
    };
    std.log.info("mutiny-setup started", .{});
}

fn claimMutex() void {
    win32.SetLastError(.NO_ERROR);
    const mutex = win32.CreateMutexW(null, 1, mutex_name);
    const err = win32.GetLastError();
    if (mutex == null or err != .NO_ERROR) {
        if (err == .ERROR_ALREADY_EXISTS) fail("Mutiny Setup is already running.", .{});
        fail("CreateMutex failed, error={f}", .{err});
    }
}

fn runInstall(install_dir: []const u8, self_exe: []const u8) void {
    claimMutex();
    std.log.info("installing to '{s}'", .{install_dir});
    std.fs.cwd().makePath(install_dir) catch |err| fail("cannot create '{s}' ({t})", .{ install_dir, err });

    closeGui();

    var total_bytes: u64 = 0;
    var present: u32 = 0;
    var written: u32 = 0;
    inline for (payload) |entry| {
        deleteFile(join(&.{ install_dir, entry.dest ++ ".old" }));
        const result = installFile(install_dir, entry.dest, decompress(@embedFile(entry.import)));
        total_bytes += result.bytes;
        switch (result.outcome) {
            .written => written += 1,
            .replaced => {
                present += 1;
                written += 1;
            },
            .unchanged => present += 1,
        }
    }

    const uninstaller = join(&.{ install_dir, setup_exe });
    if (std.ascii.eqlIgnoreCase(self_exe, uninstaller)) {
        present += 1;
    } else {
        const self_bytes = std.fs.cwd().readFileAlloc(global.arena, self_exe, std.math.maxInt(usize)) catch |err| fail(
            "read '{s}' failed ({t})",
            .{ self_exe, err },
        );
        const result = installFile(install_dir, setup_exe, self_bytes);
        total_bytes += result.bytes;
        switch (result.outcome) {
            .written => written += 1,
            .replaced => {
                present += 1;
                written += 1;
            },
            .unchanged => present += 1,
        }
    }

    const outcome: enum { installed, updated, already_installed } = if (present == 0)
        .installed
    else if (written == 0)
        .already_installed
    else
        .updated;

    const bin_dir = join(&.{ install_dir, "bin" });
    addToPath(bin_dir);
    writeShortcut(install_dir);
    writeUninstallKey(install_dir, uninstaller, total_bytes);

    std.log.info("install done: {t}", .{outcome});
    const answer = dialog.show(.{
        .title = switch (outcome) {
            .installed => "Mutiny is installed",
            .updated => "Mutiny is updated",
            .already_installed => "Mutiny was already installed",
        },
        .lines = &.{
            .{ .text = install_dir, .muted = true },
            .{ .text = "It is in the Start Menu, and 'mutiny' works in new consoles." },
        },
        .buttons = &.{
            .{ .label = "Launch Mutiny", .style = .primary },
            .{ .label = "Close", .style = .normal },
        },
    });
    if (answer.button == 0) launch(&.{join(&.{ install_dir, gui_exe })});
}

fn decompress(compressed: []const u8) []u8 {
    const size = c.FL2_findDecompressedSize(compressed.ptr, compressed.len);
    if (size == c.FL2_CONTENTSIZE_ERROR) fail("this installer is corrupt (bad payload size)", .{});
    const buf = global.arena.alloc(u8, size) catch |e| oom(e);
    const len = c.FL2_decompress(buf.ptr, buf.len, compressed.ptr, compressed.len);
    const code = c.FL2_isError(len);
    if (code != 0) fail("this installer is corrupt (decompress failed, error {} {s})", .{ code, c.FL2_getErrorString(code) });
    return buf[0..len];
}

const InstallResult = struct {
    bytes: u64,
    outcome: enum { written, replaced, unchanged },
};

fn installFile(install_dir: []const u8, dest_rel: []const u8, data: []const u8) InstallResult {
    const dest = join(&.{ install_dir, dest_rel });
    if (std.fs.path.dirname(dest)) |dir| std.fs.cwd().makePath(dir) catch |err| fail(
        "cannot create '{s}' ({t})",
        .{ dir, err },
    );

    const existing: ?[]const u8 = std.fs.cwd().readFileAlloc(global.arena, dest, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => blk: {
            std.log.warn("read '{s}' failed ({t}), replacing it", .{ dest, err });
            break :blk null;
        },
    };
    if (existing) |old| if (std.mem.eql(u8, old, data)) {
        std.log.info("'{s}' is unchanged", .{dest});
        return .{ .bytes = data.len, .outcome = .unchanged };
    };

    const tmp = std.fmt.allocPrint(global.arena, "{s}.installing", .{dest}) catch |e| oom(e);
    std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = data }) catch |err| fail(
        "write '{s}' failed ({t})",
        .{ tmp, err },
    );

    const dest_w = wide(dest);
    const tmp_w = wide(tmp);
    const flags: win32.MOVE_FILE_FLAGS = .{ .REPLACE_EXISTING = 1, .WRITE_THROUGH = 1 };
    if (0 == win32.MoveFileExW(tmp_w, dest_w, flags)) {
        const err = win32.GetLastError();
        switch (err) {
            .ERROR_ACCESS_DENIED, .ERROR_SHARING_VIOLATION, .ERROR_USER_MAPPED_FILE => {},
            else => fail("replace '{s}' failed, error={f}", .{ dest, err }),
        }
        const old = std.fmt.allocPrint(global.arena, "{s}.old", .{dest}) catch |e| oom(e);
        const old_w = wide(old);
        deleteFile(old);
        if (0 == win32.MoveFileExW(dest_w, old_w, .{ .REPLACE_EXISTING = 1 })) fail(
            "'{s}' is in use and cannot be moved aside, error={f}",
            .{ dest, win32.GetLastError() },
        );
        std.log.info("'{s}' was in use ({f}), moved it to '{s}'", .{ dest, err, old });
        if (0 == win32.MoveFileExW(tmp_w, dest_w, flags)) fail(
            "replace '{s}' failed, error={f}",
            .{ dest, win32.GetLastError() },
        );
    }
    std.log.info("installed '{s}' ({} bytes)", .{ dest, data.len });
    return .{ .bytes = data.len, .outcome = if (existing == null) .written else .replaced };
}

fn closeGui() void {
    const hwnd = win32.FindWindowW(gui_window_class, null) orelse return;
    std.log.info("asking the running gui to close", .{});
    if (0 == win32.PostMessageW(hwnd, win32.WM_CLOSE, 0, 0)) {
        std.log.warn("PostMessage(WM_CLOSE) failed, error={f}", .{win32.GetLastError()});
        return;
    }
    var waited: u32 = 0;
    while (win32.FindWindowW(gui_window_class, null) != null) : (waited += 100) {
        if (waited >= 5000) {
            std.log.warn("the gui did not close in time", .{});
            return;
        }
        win32.Sleep(100);
    }
    std.log.info("the gui closed", .{});
}

fn launch(argv: []const []const u8) void {
    var child = std.process.Child.init(argv, global.arena);
    child.spawn() catch |err| fail("launch '{s}' failed ({t})", .{ argv[0], err });
}

fn closeKey(key: win32.HKEY) void {
    const err = win32.RegCloseKey(key);
    if (err != .NO_ERROR) win32.panicWin32("RegCloseKey", err);
}

fn openEnvironmentKey() win32.HKEY {
    var key: ?win32.HKEY = null;
    const err = win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, win32.L("Environment"), 0, .{ .QUERY_VALUE = 1, .SET_VALUE = 1 }, &key);
    if (err != .NO_ERROR) fail("open HKCU\\Environment failed, error={f}", .{err});
    return key.?;
}

const PathValue = struct { kind: win32.REG_VALUE_TYPE, text: []const u16 };

fn readPath(key: win32.HKEY) PathValue {
    var kind: win32.REG_VALUE_TYPE = .NONE;
    var size: u32 = 0;
    switch (win32.RegQueryValueExW(key, win32.L("Path"), null, &kind, null, &size)) {
        .NO_ERROR => {},
        .ERROR_FILE_NOT_FOUND => return .{ .kind = .EXPAND_SZ, .text = &.{} },
        else => |err| fail("read the user PATH failed, error={f}", .{err}),
    }
    const buf = global.arena.alloc(u16, size / 2 + 1) catch |e| oom(e);
    const err = win32.RegQueryValueExW(key, win32.L("Path"), null, &kind, @ptrCast(buf.ptr), &size);
    if (err != .NO_ERROR) fail("read the user PATH failed, error={f}", .{err});
    var text = buf[0 .. size / 2];
    while (text.len > 0 and text[text.len - 1] == 0) text = text[0 .. text.len - 1];
    return .{ .kind = kind, .text = text };
}

fn writePath(key: win32.HKEY, kind: win32.REG_VALUE_TYPE, text: []const u16) void {
    const z = std.mem.concatWithSentinel(global.arena, u16, &.{text}, 0) catch |e| oom(e);
    const err = win32.RegSetValueExW(key, win32.L("Path"), 0, kind, @ptrCast(z.ptr), @intCast((z.len + 1) * 2));
    if (err != .NO_ERROR) fail("write the user PATH failed, error={f}", .{err});
    if (0 == win32.SendMessageTimeoutW(
        hwnd_broadcast,
        win32.WM_SETTINGCHANGE,
        0,
        @bitCast(@intFromPtr(win32.L("Environment"))),
        .{ .ABORTIFHUNG = 1 },
        5000,
        null,
    )) std.log.warn("broadcasting the PATH change failed, error={f}", .{win32.GetLastError()});
}

fn pathHas(text: []const u16, dir: []const u8) bool {
    var it = std.mem.splitScalar(u16, text, ';');
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(narrow(entry), dir)) return true;
    }
    return false;
}

fn addToPath(dir: []const u8) void {
    const key = openEnvironmentKey();
    defer closeKey(key);
    const current = readPath(key);
    if (pathHas(current.text, dir)) {
        std.log.info("'{s}' is already on the user PATH", .{dir});
        return;
    }
    const updated = if (current.text.len == 0)
        wide(dir)
    else
        std.mem.concat(global.arena, u16, &.{ current.text, win32.L(";"), wide(dir) }) catch |e| oom(e);
    writePath(key, current.kind, updated);
    std.log.info("added '{s}' to the user PATH", .{dir});
}

fn removeFromPath(dir: []const u8) void {
    const key = openEnvironmentKey();
    defer closeKey(key);
    const current = readPath(key);
    if (!pathHas(current.text, dir)) return;
    var kept: std.ArrayListUnmanaged(u16) = .empty;
    var it = std.mem.splitScalar(u16, current.text, ';');
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(narrow(entry), dir)) continue;
        if (kept.items.len > 0) kept.append(global.arena, ';') catch |e| oom(e);
        kept.appendSlice(global.arena, entry) catch |e| oom(e);
    }
    writePath(key, current.kind, kept.items);
    std.log.info("removed '{s}' from the user PATH", .{dir});
}

fn shortcutPath() []const u8 {
    var folder: ?win32.PWSTR = null;
    const hr = win32.SHGetKnownFolderPath(&win32.FOLDERID_Programs, @intFromEnum(win32.KF_FLAG_CREATE), null, &folder);
    if (hr < 0) fail("SHGetKnownFolderPath(Programs) failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    defer win32.CoTaskMemFree(folder);
    return join(&.{ narrow(std.mem.span(folder.?)), shortcut_name });
}

fn writeShortcut(install_dir: []const u8) void {
    const path = shortcutPath();
    const exe = join(&.{ install_dir, gui_exe });
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
        if (hr < 0) fail("CoInitializeEx failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }
    var link: *win32.IShellLinkW = undefined;
    {
        const hr = win32.CoCreateInstance(win32.CLSID_ShellLink, null, win32.CLSCTX_INPROC_SERVER, win32.IID_IShellLinkW, @ptrCast(&link));
        if (hr < 0) fail("CoCreateInstance(ShellLink) failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }
    defer _ = link.IUnknown.Release();
    if (link.SetPath(wide(exe)) < 0) fail("IShellLink.SetPath failed", .{});
    if (link.SetWorkingDirectory(wide(install_dir)) < 0) fail("IShellLink.SetWorkingDirectory failed", .{});
    if (link.SetIconLocation(wide(exe), 0) < 0) fail("IShellLink.SetIconLocation failed", .{});
    var file: *win32.IPersistFile = undefined;
    {
        const hr = link.IUnknown.QueryInterface(win32.IID_IPersistFile, @ptrCast(&file));
        if (hr < 0) fail("QueryInterface(IPersistFile) failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }
    defer _ = file.IUnknown.Release();
    const hr = file.Save(wide(path), 1);
    if (hr < 0) fail("save the shortcut '{s}' failed, hresult=0x{x}", .{ path, @as(u32, @bitCast(hr)) });
    std.log.info("wrote the shortcut '{s}'", .{path});
}

fn removeShortcut() void {
    const path = shortcutPath();
    if (0 == win32.DeleteFileW(wide(path))) switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {},
        else => |err| std.log.warn("delete '{s}' failed, error={f}", .{ path, err }),
    } else std.log.info("removed the shortcut '{s}'", .{path});
}

fn setString(key: win32.HKEY, name: [:0]const u16, value: []const u8) void {
    const z = wide(value);
    const err = win32.RegSetValueExW(key, name, 0, .SZ, @ptrCast(z.ptr), @intCast((z.len + 1) * 2));
    if (err != .NO_ERROR) fail("write the uninstall entry failed, error={f}", .{err});
}

fn setDword(key: win32.HKEY, name: [:0]const u16, value: u32) void {
    const err = win32.RegSetValueExW(key, name, 0, .DWORD, @ptrCast(&value), 4);
    if (err != .NO_ERROR) fail("write the uninstall entry failed, error={f}", .{err});
}

fn writeUninstallKey(install_dir: []const u8, uninstaller: []const u8, total_bytes: u64) void {
    var key: ?win32.HKEY = null;
    const err = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, uninstall_key, 0, null, .{}, .{ .SET_VALUE = 1, .QUERY_VALUE = 1 }, null, &key, null);
    if (err != .NO_ERROR) fail("create the uninstall entry failed, error={f}", .{err});
    defer closeKey(key.?);
    setString(key.?, win32.L("DisplayName"), "Mutiny");
    setString(key.?, win32.L("InstallLocation"), install_dir);
    setString(key.?, win32.L("DisplayIcon"), join(&.{ install_dir, gui_exe }));
    setString(key.?, win32.L("UninstallString"), std.fmt.allocPrint(global.arena, "\"{s}\" --uninstall", .{uninstaller}) catch |e| oom(e));
    setDword(key.?, win32.L("NoModify"), 1);
    setDword(key.?, win32.L("NoRepair"), 1);
    setDword(key.?, win32.L("EstimatedSize"), @intCast(total_bytes / 1024));
    std.log.info("wrote the Apps & Features entry", .{});
}

fn removeUninstallKey() void {
    switch (win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, uninstall_key)) {
        .NO_ERROR => std.log.info("removed the Apps & Features entry", .{}),
        .ERROR_FILE_NOT_FOUND => {},
        else => |err| std.log.warn("remove the Apps & Features entry failed, error={f}", .{err}),
    }
}

fn runUninstall(install_dir: []const u8, self_exe: []const u8, temp: []const u8) void {
    if (std.ascii.startsWithIgnoreCase(self_exe, install_dir)) {
        const copy = join(&.{ temp, "mutiny-uninstall.exe" });
        if (0 == win32.CopyFileW(wide(self_exe), wide(copy), 0)) fail(
            "copy '{s}' to '{s}' failed, error={f}",
            .{ self_exe, copy, win32.GetLastError() },
        );
        std.log.info("handing over to '{s}'", .{copy});
        launch(&.{ copy, "--uninstall" });
        win32.ExitProcess(0);
    }
    claimMutex();

    const answer = dialog.show(.{
        .title = "Uninstall Mutiny?",
        .lines = &.{
            .{ .text = "This removes Mutiny from" },
            .{ .text = install_dir, .muted = true },
        },
        .checkbox = "Also delete my mods, scripts, logs and the cache",
        .buttons = &.{
            .{ .label = "Uninstall", .style = .danger },
            .{ .label = "Cancel", .style = .normal },
        },
    });
    if (answer.button != 0) {
        std.log.info("cancelled", .{});
        win32.ExitProcess(0);
    }
    const delete_data = answer.checked;

    closeGui();

    inline for (payload) |entry| {
        deleteFile(join(&.{ install_dir, entry.dest }));
        deleteFile(join(&.{ install_dir, entry.dest ++ ".old" }));
        if (comptime std.mem.endsWith(u8, entry.dest, ".exe") or std.mem.endsWith(u8, entry.dest, ".dll")) {
            deleteFile(join(&.{ install_dir, entry.dest[0 .. entry.dest.len - 4] ++ ".pdb" }));
        }
    }
    deleteFile(join(&.{ install_dir, setup_exe }));
    for ([_][]const u8{ "bin", "dll" }) |sub| {
        const dir = join(&.{ install_dir, sub });
        if (0 == win32.RemoveDirectoryW(wide(dir))) switch (win32.GetLastError()) {
            .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {},
            else => |err| std.log.warn("remove '{s}' failed, error={f}", .{ dir, err }),
        };
    }
    if (delete_data) {
        std.fs.deleteTreeAbsolute(install_dir) catch |err| std.log.warn("delete '{s}' failed ({t})", .{ install_dir, err });
        std.log.info("deleted '{s}'", .{install_dir});
    } else {
        if (0 == win32.RemoveDirectoryW(wide(install_dir))) switch (win32.GetLastError()) {
            .ERROR_DIR_NOT_EMPTY, .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {},
            else => |err| std.log.warn("remove '{s}' failed, error={f}", .{ install_dir, err }),
        };
    }

    removeFromPath(join(&.{ install_dir, "bin" }));
    removeShortcut();
    removeUninstallKey();

    std.log.info("uninstall done", .{});
    _ = dialog.show(.{
        .title = "Mutiny has been removed",
        .lines = if (delete_data) &.{} else &.{
            .{ .text = "Your mods, scripts and logs are still in" },
            .{ .text = install_dir, .muted = true },
        },
        .buttons = &.{.{ .label = "Close", .style = .normal }},
    });
}

fn deleteFile(path: []const u8) void {
    if (0 == win32.DeleteFileW(wide(path))) switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {},
        else => |err| std.log.warn("delete '{s}' failed, error={f}", .{ path, err }),
    } else std.log.info("deleted '{s}'", .{path});
}

const std = @import("std");
const win32 = @import("win32").everything;
const dialog = @import("dialog.zig");
const c = @cImport({
    @cInclude("fast-lzma2.h");
    @cInclude("fl2_errors.h");
});
