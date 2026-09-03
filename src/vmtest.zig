
fn installIl2cppFixture(funcs: *const dotnet.Funcs, unity_version: UnityVersion) !void {
    const layouts = try il2cppclass.discover(funcs, unity_version);
    const il2cpp = &funcs.kind.il2cpp;
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(funcs.domain_get().?, &assembly_count);
    try il2cpptestfixture.install(funcs, std.heap.page_allocator, layouts.class, layouts.method, assemblies[0..assembly_count]);
}

pub fn run(dotnet_funcs: *const dotnet.Funcs, unity_version: UnityVersion) !void {
    if (dotnet_funcs.kind == .il2cpp) try installIl2cppFixture(dotnet_funcs, unity_version);
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
    const echo_body =
        \\@Assert(Echo.I32(0 - 32) == 0 - 32)
        \\@Assert(Echo.I64(9007199254740993) == 9007199254740993)
        \\@Assert(Echo.F32(1.5) == 1.5)
        \\@Assert(Echo.F64(3.25) == 3.25)
        \\@Assert(Echo.Bool(1) == 1)
        \\@Assert(Echo.I8(0 - 128) == 0 - 128)
        \\@Assert(Echo.U8(255) == 255)
        \\@Assert(Echo.I16(32767) == 32767)
        \\@Assert(Echo.U16(65535) == 65535)
        \\@Assert(Echo.U32(4294967295) == 4294967295)
        \\@Assert(Echo.F32(2) == 2)
        \\@Assert(Echo.F32(0 - 3) == 0 - 3)
        \\@Assert(Echo.F32(16777216) == 16777216)
        \\@Assert(Echo.F64(9007199254740992) == 9007199254740992)
        \\@Assert(Echo.F32(1.1) != 1.1)
    ;
    try Vm.testCode(dotnet_funcs, switch (dotnet_funcs.kind) {
        .mono => mono_prelude ++ echo_body,
        .il2cpp => il2cpp_prelude ++ echo_body,
    });
    const constants_body =
        \\@Assert(Constants.I64Max() == 9223372036854775807)
        \\@Assert(Echo.F64(Constants.F64Huge()) == Constants.F64Huge())
        \\@Assert(Echo.F32(Constants.F32Huge()) == Constants.F32Huge())
        \\@Assert(@IsNull(Instances.NullString()))
        \\@Assert(@IsNull(Instances.NullObject()))
    ;
    try Vm.testCode(dotnet_funcs, switch (dotnet_funcs.kind) {
        .mono => mono_prelude ++ constants_body,
        .il2cpp => il2cpp_prelude ++ constants_body,
    });
}

const mono_prelude =
    \\var mutiny_test = @Assembly("MutinyTest")
    \\var Echo = @Class(mutiny_test.MutinyTest.Echo)
    \\var Constants = @Class(mutiny_test.MutinyTest.Constants)
    \\var Instances = @Class(mutiny_test.MutinyTest.Instances)
    \\
;
const il2cpp_prelude =
    \\var mscorlib = @Assembly("mscorlib")
    \\var Echo = @Class(mscorlib.System.Int32)
    \\var Constants = @Class(mscorlib.System.Int32)
    \\var Instances = @Class(mscorlib.System.Int32)
    \\
;

const std = @import("std");
const Vm = @import("Vm.zig");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const il2cpptestfixture = @import("il2cpptestfixture.zig");
const UnityVersion = @import("UnityVersion.zig");
