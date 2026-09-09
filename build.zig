const std = @import("std");
const UpdateDll = @import("UpdateDll.zig");

fn SanitizeVariants(comptime T: type) type {
    return struct {
        sanitized: T,
        unsanitized: T,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zin_dep = b.dependency("zin", .{});
    const zin_mod = zin_dep.module("zin");
    const win32_dep = zin_dep.builder.dependency("win32", .{});
    // const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("win32");

    const zydis: SanitizeVariants(*std.Build.Module) = .{
        .sanitized = createZydisModule(b, target, optimize, .{ .sanitize_c = .full }),
        .unsanitized = createZydisModule(b, target, optimize, .{ .sanitize_c = .off }),
    };

    const test_dll = UpdateDll.create(b, .{
        .source_path = "managed/MutinyTest.cs",
        .out_path = "managed/MutinyTest.dll",
    });
    b.step(
        "update-test-dll",
        "rebuild managed/MutinyTest.dll if MutinyTest.cs changed",
    ).dependOn(&test_dll.step);

    const unity_stub_dll = UpdateDll.create(b, .{
        .source_path = "managed/UnityEngine.CoreModule.cs",
        .out_path = "managed/UnityEngine.CoreModule.dll",
    });
    const mutiny_mono_dll = UpdateDll.create(b, .{
        .source_path = "managed/MutinyMono.cs",
        .out_path = "managed/MutinyMono.dll",
        .references = &.{unity_stub_dll.path()},
    });
    b.step(
        "update-mono-dll",
        "rebuild managed/MutinyMono.dll if MutinyMono.cs or the UnityEngine stub changed",
    ).dependOn(&mutiny_mono_dll.step);

    const mutiny_mod: SanitizeVariants(*std.Build.Module) = .{
        .sanitized = b.createModule(.{
            .root_source_file = b.path("src/mutiny.zig"),
            .target = target,
        }),
        .unsanitized = b.createModule(.{
            .root_source_file = b.path("src/mutiny.zig"),
            .target = target,
        }),
    };
    if (target.result.os.tag == .windows) {
        mutiny_mod.sanitized.addImport("win32", win32_mod);
        mutiny_mod.unsanitized.addImport("win32", win32_mod);
    }
    if (target.result.cpu.arch == .x86_64) {
        mutiny_mod.sanitized.addImport("zydis", zydis.sanitized);
        mutiny_mod.unsanitized.addImport("zydis", zydis.unsanitized);
    }
    const mutiny_mono_dll_mod = b.createModule(.{ .root_source_file = mutiny_mono_dll.path() });
    mutiny_mod.sanitized.addImport("mutiny_mono_dll", mutiny_mono_dll_mod);
    mutiny_mod.unsanitized.addImport("mutiny_mono_dll", mutiny_mono_dll_mod);

    const dll_main_mod = b.createModule(.{
        .root_source_file = b.path("dll/main/main.zig"),
        .target = target,
        .imports = &.{
            // zydis_mod_santized pulls in ubsan_rt which causes Zig's panic
            // handler to use a threadlocal (_tls_index) which the injected DLL has
            // no startup to define.
            .{ .name = "mutiny", .module = mutiny_mod.unsanitized },
        },
    });
    if (target.result.os.tag == .windows) {
        dll_main_mod.addImport("win32", win32_mod);
    }

    const dll_io_mod = b.createModule(.{
        .root_source_file = b.path("dll/io/io.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "dll_main", .module = dll_main_mod },
        },
    });
    if (target.result.os.tag == .windows) {
        dll_io_mod.addImport("win32", win32_mod);
    }
    dll_main_mod.addImport("dll_io", dll_io_mod);

    const attach_mod = b.createModule(.{
        .root_source_file = b.path("dll/attach/attach.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "dll_main", .module = dll_main_mod },
        },
    });
    if (target.result.os.tag == .windows) {
        attach_mod.addImport("win32", win32_mod);
    }

    const mutiny_native_dll = b.addLibrary(.{
        .name = "Mutiny",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("dll/root/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dll_main", .module = dll_main_mod },
                .{ .name = "dll_attach", .module = attach_mod },
                // .{ .name = "managed_dll", .module = b.createModule(.{
                //     .root_source_file = mutiny_managed_dll,
                // }) },
            },
        }),
    });
    if (target.result.os.tag == .windows) {
        mutiny_native_dll.root_module.addImport("win32", win32_mod);
    }

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("mutiny-agent.md"),
        .{ .custom = "appdata" },
        "mutiny-agent.md",
    ).step);

    const install_appdata = blk: {
        const tool = b.addExecutable(.{
            .name = "installappdata",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/installappdata.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        tool.root_module.addImport("win32", win32_mod);
        const run = b.addRunArtifact(tool);
        run.step.dependOn(b.getInstallStep());
        run.addArg(b.getInstallPath(.{ .custom = "appdata" }, ""));
        b.step(
            "install-appdata",
            "install this build to %LOCALAPPDATA%\\mutiny",
        ).dependOn(&run.step);
        break :blk run;
    };

    const install_mutiny_native_dll = b.addInstallArtifact(mutiny_native_dll, .{
        .dest_dir = .{ .override = .{ .custom = "appdata/dll" } },
    });
    b.getInstallStep().dependOn(&install_mutiny_native_dll.step);

    const test_game_mono = b.addExecutable(.{
        .name = "TestGameMono",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testgamemono.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
            },
        }),
    });
    const install_test_game_mono = b.addInstallArtifact(test_game_mono, .{});
    b.step("install-testgamemono", "").dependOn(&install_test_game_mono.step);

    {
        const run = b.addRunArtifact(test_game_mono);
        run.step.dependOn(&install_test_game_mono.step);
        b.step("testgamemono-raw", "").dependOn(&run.step);
    }

    {
        const cli = b.addExecutable(.{
            .name = "mutiny",
            .root_module = b.createModule(.{
                .root_source_file = b.path("cli/cli.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mutiny", .module = mutiny_mod.sanitized },
                },
            }),
        });
        if (target.result.os.tag == .windows) {
            cli.root_module.addImport("win32", win32_mod);
        }
        const install = b.addInstallArtifact(cli, .{
            .dest_dir = .{ .override = .{ .custom = "appdata/bin" } },
        });
        install.step.dependOn(&install_mutiny_native_dll.step);
        // install.step.dependOn(&install_mutiny_managed_dll.step);

        b.getInstallStep().dependOn(&install.step);
        b.step("install-cli", "").dependOn(&install.step);

        const run = b.addRunArtifact(cli);
        run.step.dependOn(&install.step);
        if (b.args) |a| run.addArgs(a);
        b.step("cli", "").dependOn(&run.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "Mutiny",
            .root_module = b.createModule(.{
                .root_source_file = b.path("gui/gui.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mutiny", .module = mutiny_mod.sanitized },
                    .{ .name = "zin", .module = zin_mod },
                    .{ .name = "win32", .module = win32_mod },
                },
            }),
            .win32_manifest = b.path("gui/win32dpiaware.manifest"),
        });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "appdata" } },
        });
        b.step("install-gui", "").dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
        exe.addWin32ResourceFile(.{
            .file = b.path("gui/mutiny.rc"),
        });
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |a| run.addArgs(a);
        b.step("gui", "").dependOn(&run.step);
    }

    const unittest_step = b.step("unittest", "");

    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testroot.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag == .windows) {
            t.root_module.addImport("win32", win32_mod);
        }
        const run = b.addRunArtifact(t);
        unittest_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("cli/steam.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run = b.addRunArtifact(t);
        unittest_step.dependOn(&run.step);
    }

    const test_step = b.step("test", "");
    test_step.dependOn(unittest_step);

    const dotnet_test_exe = b.addExecutable(.{
        .name = "dotnet-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dotnet-test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zydis", .module = zydis.sanitized },
                .{ .name = "mutiny_test_dll", .module = b.createModule(.{
                    .root_source_file = test_dll.path(),
                }) },
                .{ .name = "mutiny_mono_dll", .module = mutiny_mono_dll_mod },
            },
        }),
    });
    if (target.result.os.tag == .windows) {
        dotnet_test_exe.root_module.addImport("win32", win32_mod);
    }
    const install_dotnet_test = b.addInstallArtifact(dotnet_test_exe, .{});
    b.step("install-dotnet-test", "").dependOn(&install_dotnet_test.step);

    {
        const dotnet_test = b.addRunArtifact(dotnet_test_exe);
        dotnet_test.step.dependOn(&install_dotnet_test.step);
        if (b.args) |args| dotnet_test.addArgs(args);
        b.step("dotnet-test", "run dotnet-test on the given DLL/PATH").dependOn(&dotnet_test.step);
    }

    for (test_games) |game| {
        const game_dir = b.fmt("{s}\\{s}", .{ steam_common, game.steam_dir });
        const dotnet_test = b.addRunArtifact(dotnet_test_exe);
        dotnet_test.step.dependOn(&install_dotnet_test.step);
        switch (game.runtime) {
            .mono => {
                dotnet_test.addArg(b.fmt("{s}\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll", .{game_dir}));
                dotnet_test.addArg("--assembly-path");
                dotnet_test.addArg(b.fmt("{s}\\{s}_Data\\Managed", .{ game_dir, game.name }));
            },
            .il2cpp => {
                dotnet_test.addArg(b.fmt("{s}\\GameAssembly.dll", .{game_dir}));
                dotnet_test.addArg("--data-dir");
                dotnet_test.addArg(b.fmt("{s}\\{s}_Data\\il2cpp_data", .{ game_dir, game.name }));
            },
        }
        b.step(
            b.fmt("test-{s}", .{game.step}),
            b.fmt(
                "run dotnet-test against {s}'s {t} runtime{s}",
                .{ game.name, game.runtime, game.note },
            ),
        ).dependOn(&dotnet_test.step);
        test_step.dependOn(&dotnet_test.step);

        if (b.graph.env_map.get("LOCALAPPDATA")) |localappdata| {
            const start = b.addSystemCommand(&.{
                b.fmt("{s}\\mutiny\\bin\\mutiny.exe", .{localappdata}),
                "start",
                b.fmt("{s}\\{s}.exe", .{ game_dir, game.name }),
            });
            start.step.dependOn(&install_appdata.step);
            b.step(
                b.fmt("start-{s}", .{game.step}),
                b.fmt("install-appdata, then start {s} with Mutiny.dll injected", .{game.name}),
            ).dependOn(&start.step);
        }
    }

    {
        const dumpty_exe = b.addExecutable(.{
            .name = "dumpty",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dumpty.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag == .windows) {
            dumpty_exe.root_module.addImport("win32", win32_mod);
        }
        const install = b.addInstallArtifact(dumpty_exe, .{});
        b.step("install-dumpty", "").dependOn(&install.step);

        const run = b.addRunArtifact(dumpty_exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| run.addArgs(args);
        b.step("dumpty", "").dependOn(&run.step);
    }
}

const steam_common = "C:\\Program Files (x86)\\Steam\\steamapps\\common";
const TestGame = struct {
    // the exe name without ".exe", the one identity everything else derives from: Unity
    // puts the game's data in "<name>_Data", and mutiny keeps the game's log and mods in
    // %LOCALAPPDATA%\mutiny\app\<name>
    name: []const u8,
    // the suffix of the "test-<step>" and "start-<step>" build steps
    step: []const u8,
    // the game's directory under steamapps\common, which is Steam's name for it and can
    // differ from the exe name ("Outer Wilds" vs OuterWilds.exe)
    steam_dir: []const u8,
    runtime: enum { mono, il2cpp },
    // appended to the test step's description
    note: []const u8 = "",
};
const test_games = [_]TestGame{
    .{ .name = "PEAK", .step = "peak", .steam_dir = "PEAK", .runtime = .mono },
    .{
        .name = "OuterWilds",
        .step = "outerwilds",
        .steam_dir = "Outer Wilds",
        .runtime = .mono,
        .note = " (Unity 2019, V1 gchandle API)",
    },
    .{ .name = "Schedule I", .step = "schedule1", .steam_dir = "Schedule I", .runtime = .il2cpp },
    .{ .name = "Gnomium", .step = "gnome", .steam_dir = "Burglin' Gnomes", .runtime = .mono },
};

fn createZydisModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    named: struct {
        sanitize_c: std.zig.SanitizeC,
    },
) *std.Build.Module {
    const zydis_dep = b.dependency("zydis", .{});
    const zycore_dep = b.dependency("zycore", .{});
    const mod = b.createModule(.{
        .root_source_file = b.path("zydis/zydis.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = named.sanitize_c,
    });
    mod.addIncludePath(zydis_dep.path("include"));
    mod.addIncludePath(zydis_dep.path("src")); // the .c files include <Generated/*.inc> from here
    mod.addIncludePath(zycore_dep.path("include"));
    mod.addCMacro("ZYDIS_STATIC_BUILD", "");
    mod.addCMacro("ZYAN_STATIC_DEFINE", "");
    mod.addCMacro("ZYAN_NO_LIBC", "");
    mod.addCSourceFiles(.{
        .root = zydis_dep.path("src"),
        .files = &.{
            "Decoder.c",
            "DecoderData.c",
            "SharedData.c",
            "Register.c",
            "Encoder.c",
            "EncoderData.c",
            "Utils.c",
        },
        .flags = &.{"-std=c11"},
    });
    mod.addCSourceFiles(.{
        .root = zycore_dep.path("src"),
        .files = &.{"Zycore.c"},
        .flags = &.{"-std=c11"},
    });
    return mod;
}
