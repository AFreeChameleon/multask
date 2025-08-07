const std = @import("std");
const commands = @import("./commands/index.zig");
const log = @import("./lib/log.zig");
const util = @import("./lib/util.zig");
const e = @import("./lib/error.zig");

pub fn main() !void {
    const args = try std.process.argsAlloc(util.gpa);
    defer std.process.argsFree(util.gpa, args);
    
    try log.init();
    if (args.len <= 1) {
        try log.printerr(error.NoArgs);
        return;
    }
    commands.run_commands(args) catch |err| {
        try log.printerr(err);
    };
}

