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
pub const dll_name_mono = "mono-2.0-bdwgc.dll";
pub const dll_name_il2cpp = "GameAssembly.dll";
