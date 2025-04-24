const std = @import("std");

const task = @import("../lib/task/index.zig");
const TaskId = task.TaskId;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const getopt = @import("../lib/args/getopt.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    help: bool,
    ids: []const TaskId
};

pub fn run() Errors!void {
    const flags = try parse_args();
    if (flags.help) return;

    for (flags.ids) |id| {
        var new_task = try task.TaskManager.get_task_from_id(
            id
        );
        if (!new_task.process.proc_exists()) {
            try log.printinfo("Task {d} is not running.", .{id});
            continue;
        }
        try new_task.process.kill_all();

        try log.printsucc("Task stopped with id {d}.", .{new_task.id});
    }
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("dh");
    var flags = Flags {
        .help = false,
        .ids = undefined
    };

    var next_val = try opts.next();
    while (!opts.optbreak) {
        if (next_val == null) {
            next_val = try opts.next();
            continue;
        }
        const opt = next_val.?;
        switch (opt.opt) {
            'h' => {
                flags.help = true;
                try log.print_help(stop_help);
                return flags;
            },
            'd' => {
                log.enable_debug();
                try log.printdebug("DEBUG MODE", .{});
            },
            else => unreachable,
        }
        next_val = try opts.next();
    }


    if (opts.args() == null) {
        return error.ParsingCommandArgsFailed;
    }
    const parsed_args = try util.parse_cmd_args(opts.args().?);
    flags.ids = parsed_args.ids.?;
    if (flags.ids.len == 0) {
        try log.print_custom_err(" Missing task id.", .{});
        return error.ParsingCommandArgsFailed;
    }

    return flags;
}

const stop_help = .{
    .{"Stops tasks by task id or namespace"},
    .{"Usage: mlt stop all"},
    .{""},
    .{"For more, run `mlt help`"},
};
