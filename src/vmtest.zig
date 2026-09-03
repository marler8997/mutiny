fn installIl2cppFixture(funcs: *const dotnet.Funcs, unity_version: UnityVersion) !void {
    const layouts = try il2cppclass.discover(funcs, unity_version);
    const il2cpp = &funcs.kind.il2cpp;
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(funcs.domain_get().?, &assembly_count);
    try il2cppclass.selfTest(funcs, assemblies[0..assembly_count], layouts, unity_version);
    if (Vm.enable_mutiny_test_class)
        try il2cpptestfixture.install(funcs, std.heap.page_allocator, layouts, unity_version, assemblies[0..assembly_count]);
}

pub fn run(dotnet_funcs: *const dotnet.Funcs, unity_version: ?UnityVersion) !void {
    if (dotnet_funcs.kind == .il2cpp) {
        // il2cpp needs the version to gate the synthetic-class layout; mono never uses it, so a
        // mono game with an unreadable UnityPlayer.dll can still run these tests.
        const version = unity_version orelse {
            std.log.err("cannot run il2cpp tests without the unity version", .{});
            return error.MissingUnityVersion;
        };
        try installIl2cppFixture(dotnet_funcs, version);
    }
    try Vm.testCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Int32 = @Class(mscorlib.System.Int32)
        \\@Assert(Int32.MaxValue == 2147483647)
        \\@Assert(Int32.MinValue == 0 - 2147483648)
        \\var Byte = @Class(mscorlib.System.Byte)
        \\@Assert(Byte.MaxValue == 255)
        \\var Int64 = @Class(mscorlib.System.Int64)
        \\@Assert(Int64.MaxValue == 9223372036854775807)
    );
    try Vm.testBadCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var Int32 = @Class(mscorlib.System.Int32)
        \\set Int32.MaxValue = 1
    , "3: cannot assign to 'MaxValue' because it is a const, which has no storage to write to");
    try Vm.testCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var String = @Class(mscorlib.System.String)
        \\@Assert(@NotNull(String.Empty))
        \\@Assert(@NotNull(String.Empty.GetType()))
    );
    try Vm.testCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var String = @Class(mscorlib.System.String)
        \\var object_type = String.Empty.GetType().get_BaseType()
        \\@Assert(@NotNull(object_type))
        \\@Assert(@IsNull(object_type.get_BaseType()))
    );
    // The one class shared with il2cpp - real Test from MutinyTest.dll on mono, a synthetic copy on
    // il2cpp - so one script text runs on both. @TestClass only exists in a test build.
    if (Vm.enable_mutiny_test_class) {
        try Vm.testCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Assert(Test.EchoI32(0 - 32) == 0 - 32)
            \\@Assert(Test.EchoI64(9007199254740993) == 9007199254740993)
            \\@Assert(Test.EchoF32(1.5) == 1.5)
            \\@Assert(Test.EchoF64(3.25) == 3.25)
            \\@Assert(Test.EchoBool(1) == 1)
            \\@Assert(Test.EchoI8(0 - 128) == 0 - 128)
            \\@Assert(Test.EchoU8(255) == 255)
            \\@Assert(Test.EchoI16(32767) == 32767)
            \\@Assert(Test.EchoU16(65535) == 65535)
            \\@Assert(Test.EchoU32(4294967295) == 4294967295)
            \\@Assert(Test.EchoF32(2) == 2)
            \\@Assert(Test.EchoF32(0 - 3) == 0 - 3)
            \\@Assert(Test.EchoF32(16777216) == 16777216)
            \\@Assert(Test.EchoF64(9007199254740992) == 9007199254740992)
            \\@Assert(Test.EchoF32(1.1) != 1.1)
        );
        try Vm.testCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Assert(Test.I64Max() == 9223372036854775807)
            \\@Assert(Test.EchoF64(Test.F64Huge()) == Test.F64Huge())
            \\@Assert(Test.EchoF32(Test.F32Huge()) == Test.F32Huge())
            \\@Assert(@IsNull(Test.NullString()))
            \\@Assert(@IsNull(Test.NullObject()))
        );
    }
}

const std = @import("std");

const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const il2cpptestfixture = @import("il2cpptestfixture.zig");

const UnityVersion = @import("UnityVersion.zig");
const Vm = @import("Vm.zig");
