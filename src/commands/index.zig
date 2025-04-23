const std = @import("std");
const Errors = @import("../lib/error.zig").Errors;
const help = @import("./help.zig");
const create = @import("./create.zig");
const start = @import("./start.zig");
const restart = @import("./restart.zig");
const stop = @import("./stop.zig");
const delete = @import("./delete.zig");
const ls = @import("./ls.zig");
const logs = @import("./logs.zig");
const health = @import("./health.zig");
const edit = @import("./edit.zig");

pub fn run_commands(args: [][:0]u8) Errors!void {
    const command = args[1];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h")) {
        try help.run();
    } else if (std.mem.eql(u8, command, "create")) {
        try create.run();
    } else if (std.mem.eql(u8, command, "start")) {
        try start.run();
    } else if (std.mem.eql(u8, command, "stop")) {
        try stop.run();
    } else if (std.mem.eql(u8, command, "restart")) {
        try restart.run();
    } else if (std.mem.eql(u8, command, "delete")) {
        try delete.run();
    } else if (std.mem.eql(u8, command, "ls")) {
        try ls.run();
    } else if (std.mem.eql(u8, command, "logs")) {
        try logs.run();
    } else if (std.mem.eql(u8, command, "health")) {
        try health.run();
    } else if (std.mem.eql(u8, command, "edit")) {
        try edit.run();
    } else {
        return error.MissingArgument;
    }
}
