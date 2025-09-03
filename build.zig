const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (
        b.graph.host.result.os.tag != .linux and 
        b.graph.host.result.os.tag != .macos and
        b.graph.host.result.os.tag != .windows
    ) {
        std.debug.print("Unsupported OS. Valid operating systems are: Linux, Macos and Windows\n", .{});
        return;
    }
    const exe = b.addExecutable(.{
        .name = "mlt",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{
            .whitelist = &.{
                .{ .os_tag = .linux },
                .{ .os_tag = .macos },
                .{ .os_tag = .windows },
            }
        }),
        .optimize = b.standardOptimizeOption(.{}),
    });

    b.installArtifact(exe);

    const zon_module = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });
    exe.root_module.addImport("build_zon", zon_module);

    // Linking libc
    exe.linkLibC();

    if (comptime builtin.target.os.tag == .windows) {
        const win_spawn_exe = b.addExecutable(.{
            .name = "spawn",
            .root_source_file = b.path("src/win_spawn.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSmall,
        });
        b.installArtifact(win_spawn_exe);
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
