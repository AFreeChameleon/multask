const std = @import("std");
const builtin = @import("builtin");
const Errors = @import("../lib/error.zig").Errors;
const help = @import("./help.zig");
const version = @import("./version.zig");
const create = @import("./create.zig");
const start = @import("./start.zig");
const restart = @import("./restart.zig");
const stop = @import("./stop.zig");
const delete = @import("./delete.zig");
const ls = @import("./ls.zig");
const logs = @import("./logs.zig");
const health = @import("./health.zig");
const edit = @import("./edit.zig");

const parse = @import("../lib/args/parse.zig");
const util = @import("../lib/util.zig");
const log = @import("../lib/log.zig");

pub fn run_commands(argv: [][]u8) Errors!void {
    const command = argv[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h")) {
        try help.run();
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "-v")) {
        try version.run();
    } else if (std.mem.eql(u8, command, "create") or std.mem.eql(u8, command, "c")) {
        // Removing the exe name and the initial command
        try create.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "start") or std.mem.eql(u8, command, "s")) {
        try start.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "stop")) {
        try stop.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "restart")) {
        try restart.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "delete")) {
        try delete.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "ls")) {
        try ls.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "logs")) {
        try logs.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "health")) {
        try health.run(argv[2..]);
    } else if (std.mem.eql(u8, command, "edit")) {
        try edit.run(argv[2..]);
    } else {
        return error.MissingArgument;
    }
}
