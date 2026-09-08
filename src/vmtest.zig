fn installIl2cppFixture(funcs: *const dotnet.Funcs, unity_version: UnityVersion) !void {
    const layouts = try il2cppclass.discover(funcs, unity_version);
    const il2cpp = &funcs.kind.il2cpp;
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(funcs.domain_get().?, &assembly_count);
    try il2cppclass.selfTest(funcs, assemblies[0..assembly_count], layouts, unity_version);
    try il2cppclass.subclassSelfTest(funcs, assemblies[0..assembly_count], layouts, unity_version);
    try testIl2cppUpdate(funcs);
    if (Vm.enable_mutiny_test_class)
        try il2cpptestfixture.install(funcs, std.heap.page_allocator, layouts, unity_version, assemblies[0..assembly_count]);
}

fn testIl2cppUpdate(funcs: *const dotnet.Funcs) !void {
    const sub_class = il2cppclass.global.subclassClass() orelse return error.SubclassNotBuilt;
    const update = funcs.class_get_method_from_name(sub_class, "Update", 0) orelse return error.SubclassUpdateNotFound;
    const cursor = @import("root").testMutinyUpdateCursor();
    var exception: ?*const dotnet.Object = null;
    _ = funcs.runtime_invoke(update, null, null, &exception);
    if (exception) |e| {
        std.log.err("synthetic Update threw {s}", .{funcs.class_get_name(funcs.object_get_class(e))});
        return error.SubclassUpdateThrew;
    }
    if (!@import("root").testMutinyUpdateCalled(cursor)) return error.SubclassUpdateNotInvoked;
    const gui = funcs.class_get_method_from_name(sub_class, "OnGUI", 0) orelse return error.SubclassGuiNotFound;
    const gui_cursor = @import("root").testMutinyGuiCursor();
    _ = funcs.runtime_invoke(gui, null, null, &exception);
    if (exception != null) return error.SubclassGuiThrew;
    if (!@import("root").testMutinyGuiCalled(gui_cursor)) return error.SubclassGuiNotInvoked;
    std.log.info("il2cpp synthetic subclass: Update and OnGUI reached the invoker and the root hooks", .{});
}

fn testMonoUpdate(funcs: *const dotnet.Funcs) !void {
    const ticker = try mutinymono.load(funcs);
    const update = funcs.class_get_method_from_name(ticker, "Update", 0) orelse return error.TickerUpdateNotFound;
    const ticker_instance = funcs.object_new(ticker) orelse return error.TickerObjectNewFailed;
    const cursor = @import("root").testMutinyUpdateCursor();
    var exception: ?*const dotnet.Object = null;
    _ = funcs.runtime_invoke(update, ticker_instance, null, &exception);
    if (exception) |e| {
        std.log.err("Ticker.Update threw {s}", .{funcs.class_get_name(funcs.object_get_class(e))});
        return error.TickerUpdateThrew;
    }
    if (!@import("root").testMutinyUpdateCalled(cursor)) return error.TickerUpdateNotInvoked;
    const gui = funcs.class_get_method_from_name(ticker, "OnGUI", 0) orelse return error.TickerGuiNotFound;
    const gui_cursor = @import("root").testMutinyGuiCursor();
    _ = funcs.runtime_invoke(gui, ticker_instance, null, &exception);
    if (exception) |e| {
        std.log.err("Ticker.OnGUI threw {s}", .{funcs.class_get_name(funcs.object_get_class(e))});
        return error.TickerGuiThrew;
    }
    if (!@import("root").testMutinyGuiCalled(gui_cursor)) return error.TickerGuiNotInvoked;
    std.log.info("mono MonoBehaviour: MutinyMono.dll loaded, Ticker.Update and OnGUI reached their internal calls", .{});
}

pub fn run(dotnet_funcs: *const dotnet.Funcs, unity_version: ?UnityVersion) !void {
    if (dotnet_funcs.kind == .mono) try testMonoUpdate(dotnet_funcs);
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
        \\var CultureInfo = @Class(mscorlib.System.Globalization.CultureInfo)
        \\@Log(CultureInfo.get_InvariantCulture())
    );
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
        \\@Assert(String.IsNullOrEmpty("") == 1)
        \\@Assert(String.IsNullOrEmpty("abc") == 0)
        \\@Assert(String.IsNullOrWhiteSpace("   ") == 1)
        \\@Assert(String.IsNullOrWhiteSpace(" x ") == 0)
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
        try Vm.testCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Assert(Test.Overload(5) == 1)
            \\@Assert(Test.Overload("x") == 2)
            \\@Assert(Test.Overload(1.5) == 3)
        );
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.EchoEnum(3))
        , switch (dotnet_funcs.kind) {
            .mono => "2: no overload matches for EchoEnum(integer) on class 'Test', candidates: EchoEnum(DayOfWeek)",
            .il2cpp => "2: no overload matches for EchoEnum(integer) on class 'Object', candidates: EchoEnum(DayOfWeek)",
        });
        try Vm.testCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Assert(Test.OverloadIntEnum(3) == 1)
            \\@Assert(Test.OverloadIntEnum(.Wednesday) == 2)
            \\@Assert(Test.EchoEnum(.Sunday) == 0)
            \\@Assert(Test.EchoEnum(.Wednesday) == 3)
            \\@Assert(Test.EchoEnum(.Saturday) == 6)
            \\var day = .Thursday
            \\@Assert(Test.EchoEnum(day) == 4)
            \\@Log("day is ", day)
        );
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.EchoEnum(.Funday))
        , "2: enum 'DayOfWeek' has no member 'Funday'");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.EchoI32(.Monday))
        , switch (dotnet_funcs.kind) {
            .mono => "2: no overload matches for EchoI32(enum_literal) on class 'Test', candidates: EchoI32(i4)",
            .il2cpp => "2: no overload matches for EchoI32(enum_literal) on class 'Object', candidates: EchoI32(i4)",
        });
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.OverloadIntUint(5))
        , switch (dotnet_funcs.kind) {
            .mono => "2: ambiguous overloads for OverloadIntUint(integer) on class 'Test', candidates: OverloadIntUint(i4) OverloadIntUint(u4)",
            .il2cpp => "2: ambiguous overloads for OverloadIntUint(integer) on class 'Object', candidates: OverloadIntUint(i4) OverloadIntUint(u4)",
        });
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.OverloadInt32And64(5))
        , switch (dotnet_funcs.kind) {
            .mono => "2: ambiguous overloads for OverloadInt32And64(integer) on class 'Test', candidates: OverloadInt32And64(i4) OverloadInt32And64(i8)",
            .il2cpp => "2: ambiguous overloads for OverloadInt32And64(integer) on class 'Object', candidates: OverloadInt32And64(i4) OverloadInt32And64(i8)",
        });
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.Overload(Test))
        , switch (dotnet_funcs.kind) {
            .mono => "2: no overload matches for Overload(other) on class 'Test', candidates: Overload(i4) Overload(string) Overload(r8)",
            .il2cpp => "2: no overload matches for Overload(other) on class 'Object', candidates: Overload(i4) Overload(string) Overload(r8)",
        });
    }
    try Vm.testBadCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var String = @Class(mscorlib.System.String)
        \\@Discard(String.IsNullOrEmpty(5))
    , "3: no overload matches for IsNullOrEmpty(integer) on class 'String', candidates: IsNullOrEmpty(string)");
    try Vm.testUpdateMod(dotnet_funcs,
        \\@UpdateResult("health is ", 100, " of ", 100)
    , .{ .result = "health is 100 of 100" });
    try Vm.testUpdateMod(dotnet_funcs,
        \\var n = 1
        \\if (n == 2) { @UpdateResult("never") }
    , .done);
    try Vm.testUpdateMod(dotnet_funcs,
        \\@Log("every frame")
    , .{ .err = "1: @Log is not supported in on-update mods, use @UpdateResult" });
    try Vm.testBadCode(dotnet_funcs,
        \\@UpdateResult("not an update mod")
    , "1: @UpdateResult is only supported in on-update mods");
    try Vm.testCode(dotnet_funcs,
        \\var n = 0
        \\loop
        \\    if (n == 110) { break }
        \\    var a = 1
        \\    var b = 2
        \\    set n = n + a + b - 2
        \\continue
    );

    try Vm.testCode(dotnet_funcs,
        \\var n = 0
        \\loop
        \\    if (n == 500) { break }
        \\    var a = 1
        \\    var b = 2
        \\    set n = n + a + b - 2
        \\continue
        \\@Assert(n == 500)
    );
    try Vm.testBadCode(dotnet_funcs,
        \\var n = 0
        \\loop
        \\    if (n == 3) { break }
        \\    var a = n
        \\    set n = n + 1
        \\continue
        \\@Log(a)
    , "7: undefined identifier 'a'");
    try Vm.testBadCode(dotnet_funcs,
        \\var n = 0
        \\loop
        \\    var a = 5
        \\    if (n == 0) { break }
        \\continue
        \\@Log(a)
    , "6: undefined identifier 'a'");
    try Vm.testCode(dotnet_funcs,
        \\var n = 0
        \\var last = 0
        \\loop
        \\    if (n == 3) { break }
        \\    var a = n + 10
        \\    set last = a
        \\    set n = n + 1
        \\continue
        \\@Assert(n == 3)
        \\@Assert(last == 12)
    );

    try Vm.testCode(dotnet_funcs,
        \\if (1 == 1) { var x = 7 }
        \\@Assert(x == 7)
    );
    try Vm.testBadCode(dotnet_funcs,
        \\if (1 == 0) { var x = 7 }
        \\@Log(x)
    , "2: undefined identifier 'x'");

    try Vm.testCode(dotnet_funcs,
        \\var n = 0
        \\loop
        \\    if (n == 3) { break }
        \\    if (1 == 1) { var x = n }
        \\    @Assert(x == n)
        \\    set n = n + 1
        \\continue
    );
    try Vm.testBadCode(dotnet_funcs,
        \\var n = 0
        \\loop
        \\    if (n == 3) { break }
        \\    if (n == 1) { var t = 1 }
        \\    set n = n + 1
        \\continue
        \\@Log(t)
    , "7: undefined identifier 't'");

    try Vm.testCode(dotnet_funcs,
        \\if (@IsFirstRun()) {
        \\    @Reschedule(500)
        \\}
        \\@Assert(@IsFirstRun() == 0)
    );
    try Vm.testBadCode(dotnet_funcs,
        \\@Reschedule(0 - 1)
    , "1: @Reschedule delay must be between 0 and 4294967295 milliseconds");

    try Vm.testCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var TimeSpan = @Class(mscorlib.System.TimeSpan)
        \\var ts = TimeSpan.FromSeconds(1)
        \\@Assert(@HasField(ts, "_ticks") == 1)
        \\@Assert(@HasField(ts, "no_such_field") == 0)
        \\@Assert(@HasField(ts, "") == 0)
    );
    try Vm.testBadCode(dotnet_funcs,
        \\@HasField(1, "x")
    , "1: expected argument 0 to be an object but got an integer");
    try Vm.testBadCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var TimeSpan = @Class(mscorlib.System.TimeSpan)
        \\@HasField(TimeSpan.FromSeconds(1), 5)
    , "3: expected argument 1 to be a string literal but got an integer");
}

const std = @import("std");

const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const mutinymono = @import("mutinymono.zig");
const il2cpptestfixture = @import("il2cpptestfixture.zig");

const UnityVersion = @import("UnityVersion.zig");
const Vm = @import("Vm.zig");
