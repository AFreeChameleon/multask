const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target_opts = b.standardTargetOptions(.{});
    const optimise_opts = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target_opts,
        .optimize = optimise_opts,
    });

    const flute = b.dependency("flute", .{
        .target = target_opts,
        .optimize = optimise_opts
    });
    const flute_mod = flute.module("flute");

    exe_mod.addImport("flute", flute_mod);

    const exe = b.addExecutable(.{
        .name = "mlt",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const zon_module = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });
    exe.root_module.addImport("build_zon", zon_module);

    // Linking libc
    exe.linkLibC();

    if (comptime builtin.target.os.tag == .windows) {
        const mlt_bg_exe = b.addExecutable(.{
            .name = "mlt_bg",
            .root_module = exe_mod,
        });
        b.installArtifact(mlt_bg_exe);
        mlt_bg_exe.root_module.addImport("build_zon", zon_module);
        mlt_bg_exe.subsystem = .Windows;
        mlt_bg_exe.linkLibC();

        const win_spawn_exe_mod = b.createModule(.{
            // `root_source_file` is the Zig "entry point" of the module. If a module
            // only contains e.g. external object files, you can make this `null`.
            // In this case the main source file is merely a path, however, in more
            // complicated build scripts, this could be a generated file.
            .root_source_file = b.path("src/win_spawn.zig"),
            .target = target_opts,
            .optimize = optimise_opts,
        });
        const win_spawn_exe = b.addExecutable(.{
            .name = "spawn",
            .root_module = win_spawn_exe_mod
        });
        win_spawn_exe_mod.addImport("flute", flute_mod);
        b.installArtifact(win_spawn_exe);
        win_spawn_exe.root_module.addImport("build_zon", zon_module);
        win_spawn_exe.linkLibC();
    }

    // Add testing
    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target_opts,
        .optimize = optimise_opts,
    });
    test_mod.addImport("flute", flute_mod);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
