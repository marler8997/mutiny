const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zin_dep = b.dependency("zin", .{});
    const zin_mod = zin_dep.module("zin");
    const win32_dep = zin_dep.builder.dependency("win32", .{});
    // const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("win32");

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
    const install_mutiny_native_dll = b.addInstallArtifact(mutiny_native_dll, .{});
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
        const injector = b.addExecutable(.{
            .name = "injector",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/injector.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "win32", .module = win32_mod },
                },
            }),
        });
        const install = b.addInstallArtifact(injector, .{});
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(injector);
        run.step.dependOn(&install.step);
        run.step.dependOn(&install_mutiny_native_dll.step);
        // run.step.dependOn(&install_mutiny_managed_dll.step);
        run.step.dependOn(&install_test_game_mono.step);

        run.addArtifactArg(mutiny_native_dll);
        run.addArtifactArg(test_game_mono);
        b.step("testgame", "").dependOn(&run.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "Mutiny",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/mutiny.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zin", .module = zin_mod },
                },
            }),
            .win32_manifest = b.path("src/win32dpiaware.manifest"),
        });
        exe.addWin32ResourceFile(.{
            .file = b.path("src/mutiny.rc"),
        });
        const run = b.addRunArtifact(exe);
        if (b.args) |a| run.addArgs(a);
        b.step("run", "").dependOn(&run.step);
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
        test_step.dependOn(&run.step);
    }

    const dotnet_test_exe = b.addExecutable(.{
        .name = "dotnet-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dotnet-test.zig"),
            .target = target,
            .optimize = optimize,
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

    {
        const mock = b.addLibrary(.{
            .name = "mono-2.0-bdwgc",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/monomock.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (target.result.os.tag == .windows) {
            mock.root_module.addImport("win32", win32_mod);
        }
        const dotnet_test = b.addRunArtifact(dotnet_test_exe);
        dotnet_test.step.dependOn(&install_dotnet_test.step);
        dotnet_test.addArg("--mock");
        dotnet_test.addArtifactArg(mock);
        b.step("dotnet-test-mock", "").dependOn(&dotnet_test.step);
        test_step.dependOn(&dotnet_test.step);
    }
}
