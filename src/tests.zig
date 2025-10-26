pub const std = @import("std");
pub const builtin = @import("builtin");
pub const expect = @import("std").testing.expect;
pub const Errors = @import("lib/error.zig").Errors;

test "Main" {
    _ = @import("lib/util.zig");
    _ = @import("lib/args/parse.zig");
    _ = @import("lib/table/index.zig");
    _ = @import("lib/table/main.zig");
    _ = @import("lib/table/stats.zig");
    _ = @import("lib/task/manager.zig");
    _ = @import("lib/task/env.zig");
    if (comptime builtin.target.os.tag == .linux) {
        _ = @import("lib/linux/file.zig");
    }
    if (comptime builtin.target.os.tag == .windows) {
        _ = @import("lib/windows/env.zig");
    }

    _ = @import("commands/create.zig");
    _ = @import("commands/delete.zig");
    _ = @import("commands/edit.zig");
    _ = @import("commands/health.zig");
    _ = @import("commands/logs.zig");
    _ = @import("commands/ls.zig");
    _ = @import("commands/start.zig");
    _ = @import("commands/restart.zig");
    _ = @import("commands/stop.zig");
    std.testing.refAllDecls(@This());
}
