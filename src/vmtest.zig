fn installIl2cppFixture(funcs: *const Funcs, unity_version: UnityVersion) !void {
    const il2cpp = &funcs.kind.il2cpp;
    const layouts = try il2cppclass.discover(&il2cpp.class, unity_version);
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(funcs.domain_get().?, &assembly_count);
    try il2cppclass.selfTest(&il2cpp.class, assemblies[0..assembly_count], layouts, unity_version);
    try il2cppclass.subclassSelfTest(&il2cpp.class, assemblies[0..assembly_count], layouts, unity_version);
    try testIl2cppUpdate(funcs);
    if (Vm.enable_mutiny_test_class)
        try il2cpptestfixture.install(&il2cpp.fixture, std.heap.page_allocator, layouts, unity_version, assemblies[0..assembly_count]);
}

fn testIl2cppUpdate(funcs: *const Funcs) !void {
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

fn testMonoUpdate(funcs: *const Funcs) !void {
    const hook = &funcs.kind.mono.hook;
    const ticker = try mutinymono.load(hook);
    try mutinymono.instantiate(hook, ticker);
    const core = mutinymono.findImage(hook, "UnityEngine.CoreModule") orelse return error.NoCoreModuleStub;
    const loop = funcs.class_from_name(core, "UnityEngine", "TestPlayerLoop") orelse return error.NoTestPlayerLoop;
    const update = funcs.class_get_method_from_name(loop, "Update", 0) orelse return error.TestPlayerLoopUpdateNotFound;
    const cursor = @import("root").testMutinyUpdateCursor();
    var exception: ?*const dotnet.Object = null;
    _ = funcs.runtime_invoke(update, null, null, &exception);
    if (exception) |e| {
        std.log.err("TestPlayerLoop.Update threw {s}", .{funcs.class_get_name(funcs.object_get_class(e))});
        return error.TestPlayerLoopUpdateThrew;
    }
    if (!@import("root").testMutinyUpdateCalled(cursor)) return error.TickerUpdateNotInvoked;
    const gui = funcs.class_get_method_from_name(loop, "OnGUI", 0) orelse return error.TestPlayerLoopGuiNotFound;
    const gui_cursor = @import("root").testMutinyGuiCursor();
    _ = funcs.runtime_invoke(gui, null, null, &exception);
    if (exception) |e| {
        std.log.err("TestPlayerLoop.OnGUI threw {s}", .{funcs.class_get_name(funcs.object_get_class(e))});
        return error.TestPlayerLoopGuiThrew;
    }
    if (!@import("root").testMutinyGuiCalled(gui_cursor)) return error.TickerGuiNotInvoked;
    std.log.info("mono MonoBehaviour: MutinyMono.dll loaded, AddComponent built the Ticker, and TestPlayerLoop reached Update and OnGUI", .{});
}

pub const Funcs = struct {
    vm: Vm.Funcs,
    domain_get: *const dotnet.shared.domain_get,
    class_from_name: *const dotnet.shared.class_from_name,
    class_get_name: *const dotnet.shared.class_get_name,
    class_get_method_from_name: *const dotnet.shared.class_get_method_from_name,
    object_get_class: *const dotnet.shared.object_get_class,
    runtime_invoke: *const dotnet.shared.runtime_invoke,
    kind: union(dotnet.Kind) {
        mono: struct {
            hook: mutinymono.Funcs,
            il: iltest.Funcs,
        },
        il2cpp: struct {
            class: il2cppclass.Funcs,
            fixture: il2cpptestfixture.Funcs,
            domain_get_assemblies: *const dotnet.il2cpp.domain_get_assemblies,
        },
    },
};

pub fn run(funcs: *const Funcs, unity_version: ?UnityVersion) !void {
    const dotnet_funcs = &funcs.vm;
    if (funcs.kind == .mono) {
        try testMonoUpdate(funcs);
        try iltest.run(&funcs.kind.mono.il);
    }
    if (funcs.kind == .il2cpp) {
        // il2cpp needs the version to gate the synthetic-class layout; mono never uses it, so a
        // mono game with an unreadable UnityPlayer.dll can still run these tests.
        const version = unity_version orelse {
            std.log.err("cannot run il2cpp tests without the unity version", .{});
            return error.MissingUnityVersion;
        };
        try installIl2cppFixture(funcs, version);
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
        try Vm.testCode(dotnet_funcs,
            \\var mscorlib = @Assembly("mscorlib")
            \\var TimeSpan = @Class(mscorlib.System.TimeSpan)
            \\var String = @Class(mscorlib.System.String)
            \\var Test = @TestClass()
            \\var second = TimeSpan.FromSeconds(1)
            \\@Assert(Test.TicksOf(second) == 10000000)
            \\@Assert(Test.TicksOf(TimeSpan.FromSeconds(2)) == 20000000)
            \\@Assert(Test.AddTicks(second, TimeSpan.FromSeconds(2), 5) == 30000005)
            \\var echoed = Test.EchoObject(second)
            \\@Assert(Test.TicksOf(echoed) == 10000000)
            \\@Assert(@IsNull(Test.EchoObject(Test.NullObject())))
            \\var type = String.Empty.GetType()
            \\@Assert(Test.TypeOrString("x") == 2)
            \\@Assert(Test.TypeOrString(String.Empty) == 2)
            \\@Assert(Test.TypeOrString(type) == 1)
            \\@Assert(Test.OverloadBoxed(type) == 1)
            \\@Assert(Test.TicksOf(TimeSpan.Zero) == 0)
            \\@Assert(TimeSpan.MaxValue._ticks == 9223372036854775807)
        );
        try Vm.testBadCode(dotnet_funcs,
            \\var mscorlib = @Assembly("mscorlib")
            \\var TimeSpan = @Class(mscorlib.System.TimeSpan)
            \\set TimeSpan.Zero._ticks = 1
        , "3: setting a field of a struct that is itself a field not implemented");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.TicksOf(Test.NullObject()))
        , switch (dotnet_funcs.kind) {
            .mono => "2: no overload matches for TicksOf(null Object) on class 'Test', candidates: TicksOf(TimeSpan)",
            .il2cpp => "2: no overload matches for TicksOf(null Object) on class 'Object', candidates: TicksOf(TimeSpan)",
        });
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.TypeOrString(Test.ObjectArray()))
        , switch (dotnet_funcs.kind) {
            .mono => "2: no overload matches for TypeOrString(Object[]) on class 'Test', candidates: TypeOrString(Type) TypeOrString(string)",
            .il2cpp => "2: no overload matches for TypeOrString(Object[]) on class 'Object', candidates: TypeOrString(Type) TypeOrString(string)",
        });
        try Vm.testBadCode(dotnet_funcs,
            \\var mscorlib = @Assembly("mscorlib")
            \\var TimeSpan = @Class(mscorlib.System.TimeSpan)
            \\var Test = @TestClass()
            \\@Discard(Test.OverloadBoxed(TimeSpan.FromSeconds(1)))
        , switch (dotnet_funcs.kind) {
            .mono => "4: ambiguous overloads for OverloadBoxed(TimeSpan) on class 'Test', candidates: OverloadBoxed(Object) OverloadBoxed(TimeSpan)",
            .il2cpp => "4: ambiguous overloads for OverloadBoxed(TimeSpan) on class 'Object', candidates: OverloadBoxed(Object) OverloadBoxed(TimeSpan)",
        });
        try Vm.testCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\@Assert(ints[0] == 10)
            \\@Assert(ints[2] == 30)
            \\var i = 1
            \\@Assert(ints[i] == 20)
            \\@Assert(ints[i + 1] == 30)
            \\@Assert(Test.I32Array()[1] == 20)
            \\var sum = 0
            \\var n = 0
            \\loop
            \\    if (n == 3) { break }
            \\    set sum = sum + ints[n]
            \\    set n = n + 1
            \\continue
            \\@Assert(sum == 60)
            \\var strs = Test.StringArray()
            \\@Assert(Test.TypeOrString(strs[1]) == 2)
            \\@Assert(@NotNull(strs[0]))
            \\@Assert(@IsNull(Test.NullString()))
            \\@Log("strs[0] is ", strs[0])
            \\var objs = Test.ObjectArray()
            \\@Assert(@NotNull(objs[0]))
            \\@Assert(Test.TicksOf(objs[0]) == 5)
            \\@Assert(@IsNull(objs[1]))
            \\@Assert(@IsNull(Test.EchoObject(objs[1])))
            \\var spans = Test.TimeSpanArray()
            \\@Assert(Test.TicksOf(spans[0]) == 1)
            \\@Assert(Test.TicksOf(spans[1]) == 2)
            \\@Assert(Test.AddTicks(spans[0], spans[1], 0) == 3)
            \\@Assert(@IsNull(Test.NullI32Array()))
            \\if (0) { @Discard(ints[99]) }
        );
        try Vm.testMod(dotnet_funcs,
            \\var mscorlib = @Assembly("mscorlib")
            \\var Boolean = @Class(mscorlib.System.Boolean)
            \\var CultureInfo = @Class(mscorlib.System.Globalization.CultureInfo)
            \\var Test = @TestClass()
            \\var invariant = CultureInfo.get_InvariantCulture()
            \\@Assert(Test.Overload(Boolean.TrueString) == 2)
            \\@Assert(Test.Overload(invariant.iso2lang) == 2)
            \\@Assert(Boolean.TrueString.get_Length() == 4)
            \\var s = Boolean.FalseString
            \\set s = invariant.iso3lang
            \\@Exit(Boolean.TrueString, " ", invariant.iso2lang, " ", s)
        , .{ .result = "True iv IVL" });
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\@Discard(ints[3])
        , "3: index 3 is out of range for an array of length 3");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\@Discard(ints[0 - 1])
        , "3: index -1 is out of range for an array of length 3");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\@Discard(ints[1.5])
        , "3: expected an integer index but got a float");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\@Discard(ints[@Nothing()])
        , "3: expected an integer index but got nothing");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test.NullI32Array()[0])
        , "2: index accessed on NULL object");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\@Discard(Test[0])
        , "2: cannot index a class, only a one-dimensional array");
        try Vm.testBadCode(dotnet_funcs,
            \\var mscorlib = @Assembly("mscorlib")
            \\var TimeSpan = @Class(mscorlib.System.TimeSpan)
            \\@Discard(TimeSpan.FromSeconds(1)[0])
        , "3: cannot index an object of class 'TimeSpan', only a one-dimensional array");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\@Discard(ints[0)
        , "3: syntax error: expected a close bracket ']' to end the index but got a close paren ')'");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\if (0) { @Discard(ints[0) }
        , "3: syntax error: expected a close bracket ']' to end the index but got a close paren ')'");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\set ints[0] = 1
        , "3: setting an array element not implemented");
        try Vm.testBadCode(dotnet_funcs,
            \\var Test = @TestClass()
            \\var ints = Test.I32Array()
            \\if (0) { set ints[0] = 1 }
        , "3: setting an array element not implemented");
    }
    try Vm.testBadCode(dotnet_funcs,
        \\var mscorlib = @Assembly("mscorlib")
        \\var String = @Class(mscorlib.System.String)
        \\@Discard(String.IsNullOrEmpty(5))
    , "3: no overload matches for IsNullOrEmpty(integer) on class 'String', candidates: IsNullOrEmpty(string)");
    try Vm.testMod(dotnet_funcs,
        \\@Exit("health is ", 100, " of ", 100)
    , .{ .result = "health is 100 of 100" });
    try Vm.testMod(dotnet_funcs,
        \\var n = 1
        \\if (n == 2) { @Exit("never") }
    , .done);
    try Vm.testMod(dotnet_funcs,
        \\@Log("every frame")
    , .{ .err = "1: @Log is not supported in mods, use @Exit" });
    {
        const text =
            \\@Section(.update)
            \\var n = 1
            \\@Exit("update ran ", n)
            \\@Section(.disable)
            \\@Nothing()
            \\@Assert(0)
        ;
        const scanned = switch (sections.scan(text)) {
            .sections => |s| s,
            .err => |err| {
                std.log.err("scan failed: {f}", .{err.fmt(text)});
                return error.TestUnexpectedError;
            },
        };
        const disable = scanned.get(.disable).?;
        try Vm.testMod(dotnet_funcs, scanned.get(.update).?.text(text), .{ .result = "update ran 1" });
        try Vm.testBadCodeAtLine(dotnet_funcs, disable.text(text), disable.first_line, "6: assert");
    }
    try Vm.testBadCode(dotnet_funcs,
        \\@Section(.update)
    , "1: unknown builtin '@Section'");
    try Vm.testCode(dotnet_funcs,
        \\@Exit("not a mod, so this is logged")
        \\@Assert(0)
    );
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
const iltest = @import("iltest.zig");
const mutinymono = @import("mutinymono.zig");
const il2cpptestfixture = @import("il2cpptestfixture.zig");
const sections = @import("sections.zig");

const UnityVersion = @import("UnityVersion.zig");
const Vm = @import("Vm.zig");
