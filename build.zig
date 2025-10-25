const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target_opts = b.standardTargetOptions(.{});
    const optimise_opts = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "mlt",
        .root_source_file = b.path("src/main.zig"),
        .target = target_opts,
        .optimize = optimise_opts,
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
            .root_source_file = b.path("src/main.zig"),
            .target = target_opts,
            .optimize = optimise_opts,
        });
        b.installArtifact(mlt_bg_exe);
        mlt_bg_exe.root_module.addImport("build_zon", zon_module);
        mlt_bg_exe.subsystem = .Windows;
        mlt_bg_exe.linkLibC();

        const win_spawn_exe = b.addExecutable(.{
            .name = "spawn",
            .root_source_file = b.path("src/win_spawn.zig"),
            .target = target_opts,
            .optimize = optimise_opts,
        });
        b.installArtifact(win_spawn_exe);
        win_spawn_exe.root_module.addImport("build_zon", zon_module);
        win_spawn_exe.linkLibC();
    }

    const test_step = b.step("test", "Run unit tests");

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host
    });
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
