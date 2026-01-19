const std = @import("std");
const log = @import("../lib/log.zig");
const e = @import("../lib/error.zig");
const util = @import("../lib/util.zig");

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
    const stdout = std.io.getStdOut().writer();
    var buf = std.io.bufferedWriter(stdout);
    var w = buf.writer();

    try log.print_help_buf(intro_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(create_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(stop_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(start_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(edit_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(restart_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(ls_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(logs_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(delete_help_rows, &w);

    w.writeByte('\n') catch return error.InternalLoggingFailed;
    try log.print_help_buf(health_help_rows, &w);

    buf.flush() catch return error.InternalLoggingFailed;
}

const intro_rows = .{
    .{"Usage: mlt [option] [flags] [values]"},
    .{"To see an individial command's options, run `mlt [command] -h`"},
    .{"options:"},
};
