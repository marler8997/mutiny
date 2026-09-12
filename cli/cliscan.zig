pub fn go(arena: std.mem.Allocator) !u8 {
    const games = try scan.unityGames(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout.interface;

    for (games) |game| {
        var path_buf: [scan.max_exe_path:0]u16 = undefined;
        const name: []const u16 = if (scan.exePath(game.pid, &path_buf)) |path|
            getname.fromExe(path) catch path
        else
            win32.L("?");
        try out.print("{d: <7} \"{f}\" {s}\n", .{
            game.pid,
            std.unicode.fmtUtf16Le(name),
            switch (scan.status(game.pid)) {
                .not_attached => "not attached",
                .attached => "attached",
                .unresponsive => "unresponsive",
            },
        });
    }

    if (games.len == 0) try out.writeAll("no Unity game is running (no window of class " ++ mutinyipc.unity_window_class_utf8 ++ ")\n");
    try out.flush();
    return 0;
}

const std = @import("std");
const win32 = @import("win32").everything;
const mutiny = @import("mutiny");

const getname = mutiny.getname;
const mutinyipc = mutiny.mutinyipc;
const scan = mutiny.scan;
