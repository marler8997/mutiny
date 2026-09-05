const std = @import("std");
const UpdateDll = @import("UpdateDll.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zin_dep = b.dependency("zin", .{});
    const zin_mod = zin_dep.module("zin");
    const win32_dep = zin_dep.builder.dependency("win32", .{});
    // const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("win32");

    // Zydis (x86-64 decoder) for the il2cpp detour
    const zydis_mod = blk: {
        const zydis_dep = b.dependency("zydis", .{});
        const zycore_dep = b.dependency("zycore", .{});
        const mod = b.createModule(.{
            .root_source_file = b.path("zydis/zydis.zig"),
            .target = target,
            .optimize = optimize,
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
        break :blk mod;
    };

    // old code that I'll probably need later in order to inject my own managed dll
    const mutiny_managed_dll = blk: {
        const compile = b.addSystemCommand(&.{
            "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
            "/target:library",
        });
        const out_dll = compile.addPrefixedOutputFileArg("/out:", "MutinyManaged.dll");
        compile.addFileArg(b.path("managed/MutinyManaged.cs"));
        break :blk out_dll;
    };
    const install_mutiny_managed_dll = b.addInstallLibFile(
        mutiny_managed_dll,
        "MutinyManaged.dll",
    );
    b.step("managed-dll", "").dependOn(&install_mutiny_managed_dll.step);

    const test_dll = UpdateDll.create(b, .{
        .source_path = "managed/MutinyTest.cs",
        .out_path = "managed/MutinyTest.dll",
    });
    b.step(
        "update-test-dll",
        "rebuild managed/MutinyTest.dll if MutinyTest.cs changed",
    ).dependOn(&test_dll.step);

    const mutiny_native_dll = b.addLibrary(.{
        .name = "Mutiny",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mutinydll.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
                // .{ .name = "managed_dll", .module = b.createModule(.{
                //     .root_source_file = mutiny_managed_dll,
                // }) },
            },
        }),
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("mutiny-agent.md"),
        .{ .custom = "appdata" },
        "mutiny-agent.md",
    ).step);

    {
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
    }

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
                .root_source_file = b.path("src/cli.zig"),
                .target = target,
                .optimize = optimize,
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
                .root_source_file = b.path("src/gui.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zin", .module = zin_mod },
                    .{ .name = "win32", .module = win32_mod },
                },
            }),
            .win32_manifest = b.path("src/win32dpiaware.manifest"),
        });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "appdata" } },
        });
        b.step("install-gui", "").dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
        exe.addWin32ResourceFile(.{
            .file = b.path("src/mutiny.rc"),
        });
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |a| run.addArgs(a);
        b.step("gui", "").dependOn(&run.step);
    }

    const test_step = b.step("test", "");
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/Vm.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag == .windows) {
            t.root_module.addImport("win32", win32_mod);
        }
        const run = b.addRunArtifact(t);
        b.step("unittest", "").dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    const dotnet_test_exe = b.addExecutable(.{
        .name = "dotnet-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dotnet-test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zydis", .module = zydis_mod },
            },
        }),
    });
    if (target.result.os.tag == .windows) {
        dotnet_test_exe.root_module.addImport("win32", win32_mod);
    }
    dotnet_test_exe.root_module.addAnonymousImport("mutiny_test_dll", .{
        .root_source_file = test_dll.path(),
    });
    const install_dotnet_test = b.addInstallArtifact(dotnet_test_exe, .{});
    b.step("install-dotnet-test", "").dependOn(&install_dotnet_test.step);

    {
        const dotnet_test = b.addRunArtifact(dotnet_test_exe);
        dotnet_test.step.dependOn(&install_dotnet_test.step);
        if (b.args) |args| dotnet_test.addArgs(args);
        b.step("dotnet-test", "run dotnet-test on the given DLL/PATH").dependOn(&dotnet_test.step);
    }

    {
        const peak = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEAK";
        const dotnet_test = b.addRunArtifact(dotnet_test_exe);
        dotnet_test.step.dependOn(&install_dotnet_test.step);
        dotnet_test.addArg(peak ++ "\\MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll");
        dotnet_test.addArg("--assembly-path");
        dotnet_test.addArg(peak ++ "\\PEAK_Data\\Managed");
        b.step(
            "test-peak",
            "run dotnet-test against PEAK's mono runtime",
        ).dependOn(&dotnet_test.step);
        test_step.dependOn(&dotnet_test.step);
    }
    {
        const schedule1 = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Schedule I";
        const dotnet_test = b.addRunArtifact(dotnet_test_exe);
        dotnet_test.step.dependOn(&install_dotnet_test.step);
        dotnet_test.addArg(schedule1 ++ "\\GameAssembly.dll");
        dotnet_test.addArg("--data-dir");
        dotnet_test.addArg(schedule1 ++ "\\Schedule I_Data\\il2cpp_data");
        b.step(
            "test-schedule1",
            "run dotnet-test against Schedule I's il2cpp runtime",
        ).dependOn(&dotnet_test.step);
        test_step.dependOn(&dotnet_test.step);
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
