const std = @import("std");
fn print_help() Errors!void {
    try log.print_help(rows);
}

const rows = .{
    .{"Usage: mlt ls -w -a"},
    .{"", "Gets stats of processes"},
    .{"flags:"},
    .{"", "-w", "Provides updating tables every 2 seconds"},
    .{"", "-a", "Show all child processes"},
    .{""},
    .{"For more, run `mlt help`"},
};
const builtin = @import("builtin");

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
    memory_limit: util.MemLimit,
    cpu_limit: util.CpuLimit,
    persist: bool,
    interactive: bool,
    ids: []const TaskId
};

pub fn run() Errors!void {
    const flags = try parse_args();
    if (flags.help) return;

    for (flags.ids) |id| {
        var new_task = try task.TaskManager.get_task_from_id(
            id
        );
        if (new_task.process.proc_exists()) {
            try new_task.process.kill_all();
        }
        if (comptime builtin.target.os.tag != .windows) {
            const unix_fork = @import("../lib/unix/fork.zig");
            try unix_fork.run_daemon(&new_task, .{
                .memory_limit = flags.memory_limit,
                .cpu_limit = flags.cpu_limit,
                .interactive = flags.interactive,
                .persist = flags.persist,
            });
        } else {
            const windows_fork = @import("../lib/windows/fork.zig");
            try windows_fork.run_daemon(&new_task, .{
                .memory_limit = flags.memory_limit,
                .cpu_limit = flags.cpu_limit,
                .interactive = flags.interactive,
                .persist = flags.persist,
            });
        }

        try log.printsucc("Task restarted with id {d}.", .{new_task.id});
    }
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("c:m:ipdh");
    var flags = Flags {
        .memory_limit = 0,
        .cpu_limit = 0,
        .interactive = false,
        .persist = false,
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
            'm' => {
                if (opt.arg == null) {
                    return error.MemoryLimitValueMissing;
                }
                const arg: []const u8 = opt.arg.?;
                flags.memory_limit = std.fmt.parseIntSizeSuffix(arg, 10)
                    catch |err| switch (err) {
                        error.InvalidCharacter => {
                            return error.MemoryLimitValueInvalid;
                        },
                        else => return error.ParsingCommandArgsFailed
                    };
            },
            'c' => {
                if (opt.arg == null) {
                    return error.CpuLimitValueMissing;
                }
                const arg: []const u8 = opt.arg.?;
                flags.cpu_limit = std.fmt.parseInt(util.CpuLimit, arg, 10)
                    catch {
                        return error.CpuLimitValueInvalid;
                    };
            },
            'i' => {
                flags.interactive = true;
            },
            'p' => {
                flags.persist = true;
            },
            'h' => {
                flags.help = true;
                try log.print_help(restart_help);
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

const restart_help = .{
    .{"Restarts tasks by task id or namespace"},
    .{"Usage: mlt restart -m 100M -c 50 -i -p all"},
    .{"flags:"},
    .{"", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "-i", "", "Interactive mode (can use aliased commands on your environment)"},
    .{"", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"For more, run `mlt help`"},
};
