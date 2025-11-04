const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("win32");

    const marler_mod_native_dll = b.addLibrary(.{
        .name = "MarlerModNative",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/marlermodnative.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
            },
        }),
    });
    const install_marler_mod_native_dll = b.addInstallArtifact(marler_mod_native_dll, .{});
    b.getInstallStep().dependOn(&install_marler_mod_native_dll.step);

    const marler_mod_managed_dll = blk: {
        const compile = b.addSystemCommand(&.{
            "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
            "/target:library",
        });
        const out_dll = compile.addPrefixedOutputFileArg("/out:", "MarlerModManaged.dll");
        compile.addFileArg(b.path("managed/MarlerModManaged.cs"));
        break :blk out_dll;
    };
    const install_marler_mod_managed_dll = b.addInstallBinFile(
        marler_mod_managed_dll,
        "MarlerModManaged.dll",
    );
    b.getInstallStep().dependOn(&install_marler_mod_managed_dll.step);

    const test_game = b.addExecutable(.{
        .name = "TestGame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testgame.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
            },
        }),
    });
    const install_test_game = b.addInstallArtifact(test_game, .{});
    {
        const run = b.addRunArtifact(test_game);
        run.step.dependOn(&install_test_game.step);
        b.step("testgame-raw", "").dependOn(&run.step);
    }

    {
        const launcher = b.addExecutable(.{
            .name = "launcher",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/launcher.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "win32", .module = win32_mod },
                },
            }),
        });
        // launcher.linkSystemLibrary("kernel32");
        // launcher.linkLibC();
        const install = b.addInstallArtifact(launcher, .{});
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(launcher);
        run.step.dependOn(&install.step);
        run.step.dependOn(&install_marler_mod_native_dll.step);
        run.step.dependOn(&install_marler_mod_managed_dll.step);
        run.step.dependOn(&install_test_game.step);

        run.addArtifactArg(marler_mod_native_dll);
        run.addFileArg(marler_mod_managed_dll);
        run.addArtifactArg(test_game);
        b.step("testgame", "").dependOn(&run.step);
    }

    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/interpret.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run = b.addRunArtifact(t);
        b.step("test", "").dependOn(&run.step);
    }
    // b.installArtifact(framework);

    // // Create a run step for the launcher
    // const run_cmd = b.addRunArtifact(launcher);
    // run_cmd.step.dependOn(b.getInstallStep());

    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    // const run_step = b.step("run", "Run the launcher");
    // run_step.dependOn(&run_cmd.step);
}
