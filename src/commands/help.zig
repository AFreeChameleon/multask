const std = @import("std");
const log = @import("../lib/log.zig");
const e = @import("../lib/error.zig");
const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const create_help_rows = @import("./create.zig").help_rows;
const stop_help_rows = @import("./stop.zig").help_rows;
const start_help_rows = @import("./start.zig").help_rows;
const edit_help_rows = @import("./edit.zig").help_rows;
const restart_help_rows = @import("./restart.zig").help_rows;
const ls_help_rows = @import("./ls.zig").help_rows;
const logs_help_rows = @import("./logs.zig").help_rows;
const delete_help_rows = @import("./delete.zig").help_rows;
const health_help_rows = @import("./health.zig").help_rows;

pub fn run() e.Errors!void {
    try log.print_help(intro_rows);

    try log.print("\n", .{});
    try log.print_help(create_help_rows);

    try log.print("\n", .{});
    try log.print_help(stop_help_rows);

    try log.print("\n", .{});
    try log.print_help(start_help_rows);

    try log.print("\n", .{});
    try log.print_help(edit_help_rows);

    try log.print("\n", .{});
    try log.print_help(restart_help_rows);

    try log.print("\n", .{});
    try log.print_help(ls_help_rows);

    try log.print("\n", .{});
    try log.print_help(logs_help_rows);

    try log.print("\n", .{});
    try log.print_help(delete_help_rows);

    try log.print("\n", .{});
    try log.print_help(health_help_rows);
}

const intro_rows = .{
    .{"Usage: mlt [option] [flags] [values]"},
    .{"To see an individial command's options, run `mlt [command] -h`"},
    .{"options:"},
};
