pub const enable_mutiny_test_class = true;

pub const mutiny_options: @import("mutiny.zig").Options = .{
    .onUpdate = onMutinyUpdate,
    .onGui = onMutinyGui,
};

var mutiny_update_called: bool = false;
const UpdateCursor = struct {};
pub fn testMutinyUpdateCursor() UpdateCursor {
    std.debug.assert(!mutiny_update_called);
    return .{};
}
pub fn testMutinyUpdateCalled(cursor: UpdateCursor) bool {
    _ = cursor;
    return mutiny_update_called;
}

fn onMutinyUpdate() callconv(.c) void {
    std.debug.assert(!mutiny_update_called);
    mutiny_update_called = true;
}
var mutiny_gui_called: bool = false;
const GuiCursor = struct {};
pub fn testMutinyGuiCursor() GuiCursor {
    std.debug.assert(!mutiny_gui_called);
    return .{};
}
pub fn testMutinyGuiCalled(cursor: GuiCursor) bool {
    _ = cursor;
    return mutiny_gui_called;
}

fn onMutinyGui() callconv(.c) void {
    std.debug.assert(!mutiny_gui_called);
    mutiny_gui_called = true;
}

pub fn main() !void {
    @import("unhandled.zig").install();
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    var opt: struct {
        assembly_path: ?[:0]const u8 = null,
        data_dir: ?[:0]const u8 = null,
        mutiny_dll: ?[:0]const u8 = null,
    } = .{};
    const args = blk: {
        const all_args = try std.process.argsAlloc(arena);
        // no need to free
        var non_option_count: usize = 0;
        var arg_index: usize = 1;
        while (arg_index < all_args.len) : (arg_index += 1) {
            const arg = all_args[arg_index];
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_count] = arg;
                non_option_count += 1;
            } else if (std.mem.eql(u8, arg, "--assembly-path")) {
                arg_index += 1;
                if (arg_index == all_args.len) errExit("--assembly-path requires an arg", .{});
                opt.assembly_path = all_args[arg_index];
            } else if (std.mem.eql(u8, arg, "--data-dir")) {
                arg_index += 1;
                if (arg_index == all_args.len) errExit("--data-dir requires an arg", .{});
                opt.data_dir = all_args[arg_index];
            } else if (std.mem.eql(u8, arg, "--mutiny-dll")) {
                arg_index += 1;
                if (arg_index == all_args.len) errExit("--mutiny-dll requires an arg", .{});
                opt.mutiny_dll = all_args[arg_index];
            } else errExit(
                "unknown cmdline option '{s}'",
                .{arg},
            );
        }
        break :blk all_args[0..non_option_count];
    };
    if (args.len == 0) {
        try std.fs.File.stderr().writeAll(
            \\Usage: dotnet-test.exe [--assembly-path ASSEMBLY_PATH] DLL
            \\
            \\NOTE:
            \\    If the Unity game is using MONO, the DLL is probably named
            \\    mono-2.0-bdwgc.dll and you'll need to specify --assembly-path
            \\    as the dir containing mscorlib.dll.
            \\
            \\    If the Unity game is using IL2CPP, the dll is probably named
            \\    GameAssembly.dll and you'll probably need to specify --data-dir
            \\    as the dir containing Metadata/global-metadata.dat
            \\
        );
        std.process.exit(0xff);
    }
    if (args.len != 1) errExit(
        "expected 1 non-option cmdline arg (the DLL) but got {}",
        .{args.len},
    );
    const dll = args[0];
    // Absolute, because il2cpp can change the working directory when it starts.
    const mutiny_dll: ?[:0]const u8 = if (opt.mutiny_dll) |path| try arena.dupeZ(u8, std.fs.cwd().realpathAlloc(arena, path) catch |e|
        errExit("resolving '{s}' failed with {t}", .{ path, e })) else null;

    const dotnet_kind = dotnethost.kindFromDllName(dll) orelse errExit(
        "unable to determine dotnet kind, dll is named neither '{s}' nor '{s}'",
        .{ dotnet.dll_name_mono, dotnet.dll_name_il2cpp },
    );
    std.log.info("loading the {t} runtime...", .{dotnet_kind});
    const host = dotnethost.load(Funcs, "dotnet-test", dotnet_kind, dll, .{
        .assembly_path = opt.assembly_path,
        .data_dir = opt.data_dir,
    }) catch |err| switch (err) {
        error.Reported => std.process.exit(0xff),
    };
    std.log.info("LoadLibrary: {s}", .{switch (host.loaded) {
        .directly => "SetDllDirectory not required",
        .after_set_dll_directory => "after SetDllDirectory",
    }});
    const dotnet_funcs = &host.funcs;
    var mono_test_image: ?*const dotnet.Image = null;
    var il2cpp_domain: ?*const dotnet.Domain = null;
    switch (dotnet_funcs.kind) {
        .mono => {
            loadStubAssembly(dotnet_funcs);
            mono_test_image = loadTestAssembly(dotnet_funcs);
        },
        .il2cpp => {
            // dotnet_funcs.kind.il2cpp.register_log_callback((struct {
            //     pub fn log(m: [*:0]const u8) callconv(.c) void {
            //         std.log.info("IL2CPP: {s}", .{std.mem.span(m)});
            //     }
            // }).log);
            testDetour(dotnet_funcs, host.module, host.domain);
            il2cpp_domain = host.domain;
        },
    }
    host.attachThread() catch |err| switch (err) {
        error.Reported => std.process.exit(0xff),
    };
    std.log.info("thread attach success", .{});
    if (mono_test_image) |image| testMonoDetour(dotnet_funcs, image);

    Vm.runTests(&dotnet_funcs.tests, findUnityVersion(arena, dll)) catch |err| {
        std.log.err("tests failed with {s}:", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        } else {
            std.log.err("    no error trace", .{});
        }
        std.process.exit(0xff);
    };
    // Last, because they attach Mutiny to this process.
    if (mutiny_dll) |path| {
        if (il2cpp_domain) |domain| {
            testIl2cppExport(dotnet_funcs, domain, path);
        } else {
            testDetourExample(dotnet_funcs, path);
        }
    }
    std.log.info("dotnet-test: success", .{});
}

// Locate the internal Class::FromIl2CppType, install a pass-through detour on it, and confirm the
// hooked export still resolves the same class through the trampoline -- proving the trampoline+patch
// are byte-correct before any real hook logic rides on them.
fn testDetour(funcs: *const Funcs, module: dynlib.Module, domain: *const dotnet.Domain) void {
    const target = detour.findFunction(module, "il2cpp_class_from_il2cpp_type") catch |e|
        errExit("locate Class::FromIl2CppType: {s}", .{@errorName(e)});
    std.log.info("detour: Class::FromIl2CppType at 0x{x}", .{target});

    const object = findClassByName(funcs, domain, "System", "Object") orelse errExit("no System.Object", .{});
    const object_type = funcs.class_get_type(object);
    const from_type: *const fn (*const dotnet.Type) callconv(.c) ?*const dotnet.Class =
        @ptrCast(dynlib.getProc(module, "il2cpp_class_from_il2cpp_type") catch unreachable);
    const before = from_type(object_type);

    const installed = detour.install(target, @intFromPtr(&il2cppclass.fromIl2CppTypeHook)) catch |e|
        errExit("detour install: {s}", .{@errorName(e)});
    il2cppclass.global.fromIl2CppTypeOrig = @ptrFromInt(installed.trampoline);

    const after = from_type(object_type);
    if (after != before or after != object)
        errExit("pass-through detour changed class_from_il2cpp_type result", .{});
    std.log.info("detour: pass-through hook validated -- resolves the same class through the trampoline", .{});

    const handle_target = detour.findTypeInfoFromTypeDefinitionIndex(module) catch |e|
        errExit("locate MetadataCache::GetTypeInfoFromTypeDefinitionIndex: {s}", .{@errorName(e)});
    std.log.info("detour: GetTypeInfoFromTypeDefinitionIndex at +0x{x}", .{handle_target - @intFromPtr(module)});

    const il2cpp = &funcs.kind.il2cpp;
    var assembly_count: usize = 0;
    const assemblies = il2cpp.domain_get_assemblies(domain, &assembly_count);
    const image = il2cpp.assembly_get_image(assemblies[0]);
    const class_before = il2cpp.image_get_class(image, 0);

    const handle_installed = detour.install(handle_target, @intFromPtr(&il2cppclass.typeInfoFromTypeDefinitionIndexHook)) catch |e|
        errExit("detour install (GetTypeInfoFromTypeDefinitionIndex): {s}", .{@errorName(e)});
    il2cppclass.global.typeInfoFromTypeDefinitionIndexOrig = @ptrFromInt(handle_installed.trampoline);

    const class_after = il2cpp.image_get_class(image, 0);
    if (class_after != class_before)
        errExit("pass-through GetTypeInfoFromTypeDefinitionIndex detour changed image_get_class result", .{});
    std.log.info("detour: GetTypeInfoFromTypeDefinitionIndex pass-through validated ({s})", .{funcs.class_get_name(class_after)});
}

// Detours compiled managed methods the way a precompiled mod does: a managed replacement with the
// same signature, and a managed stub redirected to the trampoline to call the original.
fn testMonoDetour(funcs: *const Funcs, image: *const dotnet.Image) void {
    const fixture = funcs.class_from_name(image, "MutinyTest", "DetourFixture") orelse
        errExit("no MutinyTest.DetourFixture", .{});
    const Fixture = struct {
        funcs: *const Funcs,
        class: *const dotnet.Class,

        fn method(f: @This(), name: [*:0]const u8) *const dotnet.Method {
            return f.funcs.class_get_method_from_name(f.class, name, 1) orelse
                errExit("no DetourFixture.{s}", .{name});
        }
        fn code(f: @This(), name: [*:0]const u8) usize {
            return @intFromPtr(f.funcs.kind.mono.compile_method(f.method(name)) orelse
                errExit("mono_compile_method({s}) failed", .{name}));
        }
        fn hook(f: @This(), target: [*:0]const u8, replacement: [*:0]const u8, original: [*:0]const u8) void {
            const installed = detour.installManaged(f.code(target), f.code(replacement)) catch |e|
                errExit("detour install on {s}: {t}", .{ target, e });
            _ = detour.installManaged(f.code(original), installed.trampoline) catch |e|
                errExit("detour install on {s}: {t}", .{ original, e });
        }
        fn call(f: @This(), name: [*:0]const u8, arg: i32) i32 {
            var value = arg;
            var args = [_]*anyopaque{@ptrCast(&value)};
            var exception: ?*const dotnet.Object = null;
            const result = f.funcs.runtime_invoke(f.method(name), null, @ptrCast(&args), &exception);
            if (exception) |e| errExit("DetourFixture.{s}({}) threw {s}", .{
                name, arg, f.funcs.class_get_name(f.funcs.object_get_class(e)),
            });
            const unboxed: *const i32 = @ptrCast(@alignCast(f.funcs.object_unbox(result.?)));
            return unboxed.*;
        }
        fn expect(f: @This(), name: [*:0]const u8, arg: i32, want: i32) void {
            const got = f.call(name, arg);
            if (got != want) errExit("DetourFixture.{s}({}) returned {} instead of {}", .{ name, arg, got, want });
        }
    };
    const f: Fixture = .{ .funcs = funcs, .class = fixture };
    const target_result = 5 + 0 + 1 + 2;

    f.expect("Target", 5, target_result);
    f.hook("Target", "Replacement", "Original");
    f.expect("Target", 5, target_result + 1000);
    f.expect("CallTarget", 5, target_result + 1000);
    std.log.info("detour: managed call reaches the replacement, and the stub reaches the original", .{});

    const ordinary = 7;
    const thrown_by_original = 1;
    const thrown_by_replacement = 2;
    const caught = -1;
    f.expect("CatchFromThrowingTarget", thrown_by_original, caught);
    f.hook("ThrowingTarget", "ThrowingReplacement", "ThrowingOriginal");
    f.expect("CatchFromThrowingTarget", ordinary, ordinary);
    f.expect("CatchFromThrowingTarget", thrown_by_original, caught);
    f.expect("CatchFromThrowingTarget", thrown_by_replacement, caught);
    std.log.info("detour: exceptions from the replacement and through the trampoline are catchable", .{});

    // Whatever this runtime's JIT emits, a null check must stay catchable: either the hook is refused,
    // or the check wasn't displaced. Before the refusal this took the whole process down.
    f.expect("CatchFromNullCheckTarget", 0, caught);
    if (detour.installManaged(f.code("NullCheckTarget"), f.code("NullCheckReplacement"))) |installed| {
        _ = detour.installManaged(f.code("NullCheckOriginal"), installed.trampoline) catch |e|
            errExit("detour install on NullCheckOriginal: {t}", .{e});
        std.log.info("detour: this runtime's NullCheckTarget doesn't displace its null check", .{});
    } else |err| switch (err) {
        error.PrologueMayFault => std.log.info("detour: refused to displace NullCheckTarget's null check", .{}),
        else => errExit("detour install on NullCheckTarget: {t}", .{err}),
    }
    f.expect("CatchFromNullCheckTarget", 0, caught);
}

// Runs managed/DetourExample.cs the way a mod would, from before Mutiny.dll is loaded until its hook
// works.
fn testDetourExample(funcs: *const Funcs, mutiny_dll: [:0]const u8) void {
    const image = loadEmbeddedAssembly(funcs, detour_example_dll, "DetourExample");
    const example = funcs.class_from_name(image, "MutinyExample", "DetourExample") orelse
        errExit("no MutinyExample.DetourExample", .{});
    const game = funcs.class_from_name(image, "MutinyExample", "Game") orelse
        errExit("no MutinyExample.Game", .{});
    const try_install = funcs.class_get_method_from_name(example, "TryInstall", 0) orelse
        errExit("no DetourExample.TryInstall", .{});
    const score = funcs.class_get_method_from_name(game, "Score", 1) orelse
        errExit("no Game.Score", .{});
    const Example = struct {
        fn tryInstall(f: *const Funcs, method: *const dotnet.Method) error{Threw}!bool {
            var exception: ?*const dotnet.Object = null;
            const result = f.runtime_invoke(method, null, null, &exception);
            if (exception != null) return error.Threw;
            const unboxed: *const bool = @ptrCast(@alignCast(f.object_unbox(result.?)));
            return unboxed.*;
        }
        fn mustTryInstall(f: *const Funcs, method: *const dotnet.Method) bool {
            return tryInstall(f, method) catch errExit("DetourExample.TryInstall threw", .{});
        }
        fn callScore(f: *const Funcs, method: *const dotnet.Method, arg: i32) i32 {
            var value = arg;
            var args = [_]*anyopaque{@ptrCast(&value)};
            var exception: ?*const dotnet.Object = null;
            const result = f.runtime_invoke(method, null, @ptrCast(&args), &exception);
            if (exception) |e| errExit("Game.Score threw {s}", .{f.class_get_name(f.object_get_class(e))});
            const unboxed: *const i32 = @ptrCast(@alignCast(f.object_unbox(result.?)));
            return unboxed.*;
        }
    };

    if (Example.mustTryInstall(funcs, try_install)) errExit("TryInstall succeeded with no Mutiny.dll loaded", .{});

    const module = loadMutiny(mutiny_dll);
    if (Example.mustTryInstall(funcs, try_install)) errExit("TryInstall succeeded with nothing attached", .{});
    attachMutiny(module);

    const unhooked = Example.callScore(funcs, score, 5);
    var waited_ms: u32 = 0;
    while (!Example.mustTryInstall(funcs, try_install)) : (waited_ms += 10) {
        if (waited_ms > attach_timeout_ms) errExit("TryInstall still waiting after {} ms", .{waited_ms});
        win32.Sleep(10);
    }
    const hooked = Example.callScore(funcs, score, 5);
    if (hooked != unhooked + 1000) errExit("Game.Score went from {} to {}", .{ unhooked, hooked });

    // The target is hooked now, so installing again fails: once with a throw, then quietly.
    std.log.info("detour: DetourExample should fail below, by hooking twice", .{});
    if (Example.tryInstall(funcs, try_install)) |_| {
        errExit("hooking twice didn't throw", .{});
    } else |_| {}
    if (Example.mustTryInstall(funcs, try_install)) errExit("TryInstall succeeded after failing", .{});
    std.log.info("detour: DetourExample waits for Mutiny.dll, then the main thread, and its hook works", .{});
}

const attach_timeout_ms = 10000;

fn loadMutiny(mutiny_dll: [:0]const u8) dynlib.Module {
    // Attaching writes under LOCALAPPDATA, so point it somewhere that isn't the real Mutiny install.
    var temp_buf: [win32.MAX_PATH + 1]u16 = undefined;
    const temp_len = win32.GetTempPathW(temp_buf.len, @ptrCast(&temp_buf));
    if (temp_len == 0 or temp_len >= temp_buf.len) errExit("GetTempPath failed, error={f}", .{win32.GetLastError()});
    if (win32.SetEnvironmentVariableW(win32.L("LOCALAPPDATA"), @ptrCast(&temp_buf)) == 0)
        errExit("SetEnvironmentVariable failed, error={f}", .{win32.GetLastError()});
    return dynlib.load(mutiny_dll) catch |e| errExit("loading '{s}' failed with {t}", .{ mutiny_dll, e });
}

// Attaching needs a game window, and this makes one on this thread so it's the main thread. It never
// pumps messages, so Mutiny never gets as far as loading into this process's runtime.
fn attachMutiny(module: dynlib.Module) void {
    const hinstance = win32.GetModuleHandleW(null);
    const window_class: win32.WNDCLASSW = .{
        .style = .{},
        .lpfnWndProc = win32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = win32.L("UnityWndClass"),
    };
    if (win32.RegisterClassW(&window_class) == 0) errExit("RegisterClass failed, error={f}", .{win32.GetLastError()});
    if (win32.CreateWindowExW(
        .{},
        win32.L("UnityWndClass"),
        win32.L("dotnet-test"),
        .{},
        0,
        0,
        1,
        1,
        null,
        null,
        hinstance,
        null,
    ) == null) errExit("CreateWindow failed, error={f}", .{win32.GetLastError()});
    const attach: win32.LPTHREAD_START_ROUTINE = @ptrCast(dynlib.getProc(module, "MutinyAttach") catch |e|
        errExit("finding MutinyAttach failed with {t}", .{e}));
    if (win32.CreateThread(null, 0, attach, @ptrFromInt(attach_timeout_ms), .{}, null) == null)
        errExit("CreateThread failed, error={f}", .{win32.GetLastError()});
}

// What a native mod does on il2cpp: find a game method's code through il2cpp, hook it through the
// export with a native function, and call the original through the trampoline. The hook takes the
// hidden MethodInfo parameter that il2cpp adds to every method, and passes it on.
fn testIl2cppExport(funcs: *const Funcs, domain: *const dotnet.Domain, mutiny_dll: [:0]const u8) void {
    const class = findClassByName(funcs, domain, "System", "Int32") orelse errExit("no System.Int32", .{});
    const parse = funcs.class_get_method_from_name(class, "Parse", 1) orelse errExit("no Int32.Parse(string)", .{});
    const target = @as(*const usize, @ptrCast(@alignCast(parse))).*;

    const Parse = struct {
        var original: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) i32 = undefined;
        fn hook(text: ?*const anyopaque, method: ?*const anyopaque) callconv(.c) i32 {
            return original(text, method) + 1000;
        }
        /// null if it threw, and the name of what it threw in `thrown`.
        fn call(f: *const Funcs, method: *const dotnet.Method, text: []const u8, thrown: *[*:0]const u8) ?i32 {
            const string = f.kind.il2cpp.string_new_len(text.ptr, @intCast(text.len)) orelse errExit("string_new_len failed", .{});
            var args = [_]*anyopaque{@ptrCast(@constCast(string))};
            var exception: ?*const dotnet.Object = null;
            const result = f.runtime_invoke(method, null, @ptrCast(&args), &exception);
            if (exception) |e| {
                thrown.* = f.class_get_name(f.object_get_class(e));
                return null;
            }
            const unboxed: *const i32 = @ptrCast(@alignCast(f.object_unbox(result.?)));
            return unboxed.*;
        }
    };
    var thrown: [*:0]const u8 = "";
    if (Parse.call(funcs, parse, "5", &thrown) != 5) errExit("Int32.Parse(\"5\") isn't 5 before hooking", .{});

    const module = loadMutiny(mutiny_dll);
    const install: detour.DetourInstallFunction = @ptrCast(dynlib.getProc(module, "DetourInstall") catch |e|
        errExit("finding DetourInstall failed with {t}", .{e}));
    attachMutiny(module);

    var trampoline: usize = 0;
    var waited_ms: u32 = 0;
    while (true) : (waited_ms += 10) {
        const result = install(target, @intFromPtr(&Parse.hook), &trampoline);
        if (result == .ok) break;
        if (result != .not_ready) errExit("DetourInstall on Int32.Parse answered {t}", .{result});
        if (waited_ms > attach_timeout_ms) errExit("DetourInstall still answering not ready after {} ms", .{waited_ms});
        win32.Sleep(10);
    }
    Parse.original = @ptrFromInt(trampoline);

    const hooked = Parse.call(funcs, parse, "5", &thrown) orelse errExit("hooked Int32.Parse threw {s}", .{thrown});
    if (hooked != 1005) errExit("hooked Int32.Parse(\"5\") returned {}", .{hooked});

    if (Parse.call(funcs, parse, "not a number", &thrown)) |v| errExit("hooked Int32.Parse of junk returned {}", .{v});
    std.log.info("detour: il2cpp caught {s} thrown from the original, through a native hook", .{thrown});
    if (std.mem.orderZ(u8, thrown, "FormatException") != .eq) errExit("expected FormatException, got {s}", .{thrown});

    const again = Parse.call(funcs, parse, "7", &thrown) orelse errExit("hooked Int32.Parse threw {s} after a throw", .{thrown});
    if (again != 1007) errExit("hooked Int32.Parse(\"7\") returned {} after a throw", .{again});

    var second: usize = 0;
    const result = install(target, @intFromPtr(&Parse.hook), &second);
    if (result != .failed) errExit("a second hook on Int32.Parse answered {t}", .{result});
    std.log.info("detour: il2cpp native hook through the export works", .{});
}

fn findClassByName(
    funcs: *const Funcs,
    domain: *const dotnet.Domain,
    namespace: [*:0]const u8,
    name: [*:0]const u8,
) ?*const dotnet.Class {
    var count: usize = 0;
    const assemblies = funcs.kind.il2cpp.domain_get_assemblies(domain, &count);
    for (assemblies[0..count]) |assembly| {
        const image = funcs.assembly_get_image(assembly) orelse continue;
        if (funcs.class_from_name(image, namespace, name)) |class| return class;
    }
    return null;
}

const Funcs = struct {
    tests: vmtest.Funcs,
    get_root_domain: *const dotnet.shared.get_root_domain,
    domain_get: *const dotnet.shared.domain_get,
    thread_attach: *const dotnet.shared.thread_attach,
    assembly_get_image: *const dotnet.shared.assembly_get_image,
    class_from_name: *const dotnet.shared.class_from_name,
    class_get_type: *const dotnet.shared.class_get_type,
    class_get_name: *const dotnet.shared.class_get_name,
    class_get_method_from_name: *const dotnet.shared.class_get_method_from_name,
    object_get_class: *const dotnet.shared.object_get_class,
    object_unbox: *const dotnet.shared.object_unbox,
    runtime_invoke: *const dotnet.shared.runtime_invoke,
    kind: union(dotnet.Kind) {
        mono: struct {
            jit_init: *const dotnet.mono.jit_init,
            set_assemblies_path: *const dotnet.mono.set_assemblies_path,
            image_open_from_data: *const dotnet.mono.image_open_from_data,
            assembly_load_from: *const dotnet.mono.assembly_load_from,
            compile_method: *const dotnet.mono.compile_method,
        },
        il2cpp: struct {
            register_log_callback: *const dotnet.il2cpp.register_log_callback,
            set_data_dir: *const dotnet.il2cpp.set_data_dir,
            init: *const dotnet.il2cpp.init,
            domain_get_assemblies: *const dotnet.il2cpp.domain_get_assemblies,
            assembly_get_image: *const dotnet.il2cpp.assembly_get_image,
            image_get_class: *const dotnet.il2cpp.image_get_class,
            string_new_len: *const dotnet.il2cpp.string_new_len,
        },
    },
};

const unity_core_stub_dll = @embedFile("unity_core_stub_dll");

fn loadStubAssembly(funcs: *const Funcs) void {
    const mono = &funcs.kind.mono;
    var status: dotnet.MonoImageOpenStatus = .ok;
    const image = mono.image_open_from_data(
        unity_core_stub_dll,
        @intCast(unity_core_stub_dll.len),
        1,
        &status,
    ) orelse errExit("mono_image_open_from_data(UnityEngine.CoreModule stub) failed with {t}", .{status});
    if (status != .ok) errExit("mono_image_open_from_data(UnityEngine.CoreModule stub) gave status {t}", .{status});
    _ = mono.assembly_load_from(image, "UnityEngine.CoreModule", &status) orelse errExit(
        "mono_assembly_load_from(UnityEngine.CoreModule stub) failed with {t}",
        .{status},
    );
    if (status != .ok) errExit("mono_assembly_load_from(UnityEngine.CoreModule stub) gave status {t}", .{status});
    std.log.info("loaded the embedded UnityEngine.CoreModule stub ({} bytes)", .{unity_core_stub_dll.len});
}

const mutiny_test_dll = @embedFile("mutiny_test_dll");
const detour_example_dll = @embedFile("detour_example_dll");

fn loadTestAssembly(funcs: *const Funcs) *const dotnet.Image {
    return loadEmbeddedAssembly(funcs, mutiny_test_dll, "MutinyTest");
}

fn loadEmbeddedAssembly(funcs: *const Funcs, data: []const u8, name: [:0]const u8) *const dotnet.Image {
    const mono = &funcs.kind.mono;
    var status: dotnet.MonoImageOpenStatus = .ok;
    const image = mono.image_open_from_data(
        data.ptr,
        @intCast(data.len),
        1,
        &status,
    ) orelse errExit("mono_image_open_from_data failed with {t}", .{status});
    if (status != .ok) errExit("mono_image_open_from_data gave status {t}", .{status});
    _ = mono.assembly_load_from(image, name, &status) orelse errExit(
        "mono_assembly_load_from failed with {t}",
        .{status},
    );
    if (status != .ok) errExit("mono_assembly_load_from gave status {t}", .{status});
    std.log.info("loaded embedded {s}.dll ({} bytes)", .{ name, data.len });
    return image;
}

// UnityPlayer.dll carries the engine version, and it sits at the game root - the same dir as
// GameAssembly.dll for il2cpp, a couple up from the mono runtime - so walk up from the runtime
// dll until it turns up. mutinydll reads the same file from the loaded module in-process.
fn findUnityVersion(arena: std.mem.Allocator, dll: []const u8) UnityVersion {
    var dir: ?[]const u8 = std.fs.path.dirname(dll);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const candidate = std.fs.path.join(arena, &.{ d, "UnityPlayer.dll" }) catch |e| errExit("{t}", .{e});
        std.fs.cwd().access(candidate, .{}) catch continue;
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(arena, candidate) catch |e| errExit("{t}", .{e});
        const version = UnityVersion.fromFile(path_w) catch |err| errExit(
            "reading the unity version from '{s}' failed with {t}",
            .{ candidate, err },
        );
        std.log.info("unity version: {f} (from {s})", .{ version, candidate });
        return version;
    }
    errExit("could not find UnityPlayer.dll near '{s}' to read the unity version", .{dll});
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const detour = @import("detour.zig");
const dynlib = @import("dynlib.zig");
const dotnet = @import("dotnet.zig");
const il2cppclass = @import("il2cppclass.zig");
const dotnethost = @import("dotnethost.zig");
const win32 = @import("win32").everything;
const vmtest = @import("vmtest.zig");

const UnityVersion = @import("UnityVersion.zig");
const Vm = @import("Vm.zig");
