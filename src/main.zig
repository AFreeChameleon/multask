const std = @import("std");
const commands = @import("./commands/index.zig");
const log = @import("./lib/log.zig");
const util = @import("./lib/util.zig");
const parse = @import("./lib/args/parse.zig");
const e = @import("./lib/error.zig");

pub fn main() !void {
    const argv = try parse.get_slice_args();
    defer {
        for (argv) |a| {
            util.gpa.free(a);
        }
        util.gpa.free(argv);
    }
    if (argv.len > 1 and !std.mem.eql(u8, argv[1], "startup")) {
        try log.init();
    }

    if (argv.len <= 1) {
        try log.printerr(error.NoArgs);
        return;
    }
    commands.run_commands(argv) catch |err| {
        try log.printerr(err);
    };
}

