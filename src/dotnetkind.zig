pub const Kind = enum {
    mono,
    il2cpp,
    pub fn dllName(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .mono => dll_name_mono,
            .il2cpp => dll_name_il2cpp,
        };
    }
};
pub const dll_name_mono = switch (builtin.os.tag) {
    .windows => "mono-2.0-bdwgc.dll",
    else => "libmono-2.0-bdwgc.so",
};
pub const dll_name_il2cpp = switch (builtin.os.tag) {
    .windows => "GameAssembly.dll",
    else => "GameAssembly.so",
};

const builtin = @import("builtin");
