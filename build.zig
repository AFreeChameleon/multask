const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "mlt",
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSmall,
    });

    b.installArtifact(exe);

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
}
