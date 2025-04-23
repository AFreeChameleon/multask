const std = @import("std");
const unix_fork = @import("../lib/unix/fork.zig");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const TaskManager = t.TaskManager;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const getopt = @import("../lib/args/getopt.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    lines: u32,
    watch: bool,
    ids: []const TaskId,
    help: bool,
};

pub fn run() Errors!void {
    const flags = try parse_args();
    if (flags.help) return;
    const id = flags.ids[0];
    var task = try TaskManager.get_task_from_id(
        id
    );
    const last_lines: u32 = if (flags.lines == 0) 20 else flags.lines;
    // Task read last lines
    try log.printinfo("Getting last {d} lines.", .{last_lines});
    try task.files.read_last_logs(last_lines);
    if (flags.watch) {
        try log.printinfo("Listening to new lines...", .{});
        try log.printdebug("Listening is still buggy - logs don't sync properly.", .{});
        // Task watch future lines by attaching to the /proc/{id}/fd/1 and 2 handles
        try task.files.listen_log_files();
    }
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("l:wdh");
    var flags = Flags {
        .help = false,
        .lines = 0,
        .watch = false,
        .ids = undefined,
    };

    var next_val = try opts.next();
    while (!opts.optbreak) {
        if (next_val == null) {
            next_val = try opts.next();
            continue;
        }
        const opt = next_val.?;
        switch (opt.opt) {
            'l' => {
                const arg: []const u8 = opt.arg.?;
                flags.lines = std.fmt.parseInt(u32, arg, 10)
                    catch |err| switch (err) {
                        error.InvalidCharacter => {
                            try log.print_custom_err("Lines must be a number above 1.", .{});
                            return error.ParsingCommandArgsFailed;
                        },
                        else => return error.ParsingCommandArgsFailed
                    };
            },
            'w' => flags.watch = true,
            'h' => {
                flags.help = true;
                try print_help();
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
    if (flags.ids.len > 1) {
        try log.print_custom_err(" Only one task id allowed.", .{});
        return error.ParsingCommandArgsFailed;
    }
    if (flags.ids.len == 0) {
        try log.print_custom_err(" Missing task id.", .{});
        return error.ParsingCommandArgsFailed;
    }

    return flags;
}

fn print_help() Errors!void {
    try log.print_help(rows);
}

const rows = .{
    .{"Reads logs of the task"},
    .{"Usage: mlt logs -l 1000 -w 1"},
    .{"flags:"},
    .{"", "-l [num]", "Get number of previous lines, default is 20"},
    .{"", "-w", "", "Listen to new logs coming in"},
    .{""},
    .{"For more, run `mlt help`"},
};
