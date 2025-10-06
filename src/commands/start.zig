const std = @import("std");
const expect = std.testing.expect;
const builtin = @import("builtin");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const Monitoring = @import("../lib/task/process.zig").Monitoring;

const TaskManager = @import("../lib/task/manager.zig").TaskManager;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");

const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    memory_limit: ?util.MemLimit,
    cpu_limit: ?util.CpuLimit,
    persist: ?bool,
    interactive: ?bool,
    help: bool,
    update_envs: bool,
    args: util.TaskArgs,
    monitoring: ?Monitoring
};

pub fn run(argv: [][]u8) Errors!void {
    var flags = try parse_cmd_args(argv);
    defer flags.args.deinit();
    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    if (flags.args.ids == null) {
        try log.print_custom_err(" Missing task id.", .{});
        return error.ParsingCommandArgsFailed;
    }

    if (flags.update_envs) {
        try log.printinfo("Updating environment variables...", .{});
    }

    for (flags.args.ids.?) |id| {
        // Files are closed in the forked process
        var new_task = Task.init(id);
        try TaskManager.get_task_from_id(
            &new_task
        );
        if (flags.memory_limit != null) {
            new_task.stats.?.memory_limit = flags.memory_limit.?;
        }
        if (flags.cpu_limit != null) {
            new_task.stats.?.cpu_limit = flags.cpu_limit.?;
        }
        if (flags.interactive != null) {
            new_task.stats.?.interactive = flags.interactive.?;
        }
        if (flags.persist != null) {
            new_task.stats.?.persist = flags.persist.?;
        }
        if (flags.monitoring != null) {
            new_task.stats.?.monitoring = flags.monitoring.?;
        }

        if (try TaskManager.task_running(&new_task)) {
            try log.printinfo("Task {d} is already running.", .{id});
            continue;
        }
        if (comptime builtin.target.os.tag != .windows) {
            const unix_fork = @import("../lib/unix/fork.zig");
            try unix_fork.run_daemon(&new_task, .{
                .memory_limit = flags.memory_limit,
                .cpu_limit = flags.cpu_limit,
                .interactive = flags.interactive,
                .persist = flags.persist,
                .update_envs = flags.update_envs
            });
        } else {
            const windows_fork = @import("../lib/windows/fork.zig");
            try windows_fork.run_daemon(&new_task, .{
                .memory_limit = flags.memory_limit,
                .cpu_limit = flags.cpu_limit,
                .interactive = flags.interactive,
                .persist = flags.persist,
                .update_envs = flags.update_envs
            });
            defer new_task.deinit();
        }

        try log.printsucc("Task started with id {d}.", .{new_task.id});
    }
}

fn parse_cmd_args(argv: [][]u8) Errors!Flags {
    var flags = Flags {
        .memory_limit = null,
        .cpu_limit = null,
        .persist = null,
        .interactive = null,
        .help = false,
        .args = undefined,
        .update_envs = false,
        .monitoring = null
    };
    var pflags = util.gpa.alloc(parse.Flag, 10)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    defer util.gpa.free(pflags);
    pflags[0] = parse.Flag {
        .name = 'c',
        .type = .value
    };
    pflags[1] = parse.Flag {
        .name = 'm',
        .type = .value
    };
    pflags[2] = parse.Flag {
        .name = 'i',
        .type = .static,
        .long_name = "interactive"
    };
    pflags[3] = parse.Flag {
        .name = 'I',
        .type = .static,
        .long_name = "disable-interactive"
    };
    pflags[4] = parse.Flag {
        .name = 'p',
        .type = .static,
        .long_name = "persist"
    };
    pflags[5] = parse.Flag {
        .name = 'P',
        .type = .static,
        .long_name = "disable-persist",
    };
    pflags[6] = parse.Flag {
        .name = 'd',
        .type = .static
    };
    pflags[7] = parse.Flag {
        .name = 'h',
        .type = .static
    };
    pflags[8] = parse.Flag {
        .name = 'e',
        .long_name = "update-env",
        .type = .static
    };
    pflags[9] = parse.Flag {
        .name = 's',
        .long_name = "search",
        .type = .value
    };

    const vals = try parse.parse_args(argv, pflags);
    defer util.gpa.free(vals);

    for (pflags) |flag| {
        if (!flag.exists) {
            continue;
        }
        switch (flag.name) {
            'c' => {
                if (std.mem.eql(u8, flag.value.?, "none")) {
                    flags.cpu_limit = 0;
                } else {
                    flags.cpu_limit = std.fmt.parseInt(util.CpuLimit, flag.value.?, 10)
                        catch return error.CpuLimitValueInvalid;
                }
            },
            'm' => {
                if (std.mem.eql(u8, flag.value.?, "none")) {
                    flags.memory_limit = 0;
                } else {
                    flags.memory_limit = std.fmt.parseIntSizeSuffix(flag.value.?, 10)
                        catch |err| switch (err) {
                            error.InvalidCharacter => {
                                return error.MemoryLimitValueInvalid;
                            },
                            else => return error.ParsingCommandArgsFailed
                        };
                }
            },
            'd' => log.enable_debug(),
            'h' => flags.help = true,

            'i' => flags.interactive = true,
            'I' => flags.interactive = false,

            'p' => flags.persist = true,
            'P' => flags.persist = false,

            'e' => flags.update_envs = true,
            's' => flags.monitoring = try util.read_monitoring_from_string(flag.value.?),
            else => continue
        }
    }
    const parsed_args = try util.parse_cmd_vals(vals);
    flags.args = parsed_args;
    if (vals.len == 0 and !flags.help) {
        flags.args.deinit();
        return error.MissingTaskId;
    }
    return flags;
}

pub const help_rows = .{
    .{"mlt start"},
    .{"Starts tasks by task id or namespace"},
    .{"Usage: mlt start -m 100M -c 50 -i -p all"},
    .{"Flags:"},
    .{"", "-m [num]", "", "Set maximum memory limit e.g 4GB. Set to `none` to remove it."},
    .{"", "-c [num]", "", "Set limit cpu usage by percentage e.g 20. Set to `none` to remove it."},

    .{"", "-i", "", "", "Interactive mode (can use aliased commands on your environment)"},
    .{"", "-I", "", "", "Disable interactive mode"},

    .{"", "-p", "", "", "Persist mode (will restart if the program exits)"},
    .{"", "-P", "", "", "Disable persist mode"},

    .{"", "-e", "", "", "Updates env variables with your current environment."},
    .{"", "-s, --search [text]", "Makes this task look for child processes more thoroughly. Can either set to `deep` or `shallow`."},
    .{""},
};

test "commands/start.zig" {
    std.debug.print("\n--- commands/start.zig ---\n", .{});
}

test "Parse start command args" {
    std.debug.print("Parse start command args\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const memf = try std.fmt.allocPrint(util.gpa, "-m", .{});
    defer util.gpa.free(memf);
    try args.append(memf);
    const memv = try std.fmt.allocPrint(util.gpa, "20k", .{});
    defer util.gpa.free(memv);
    try args.append(memv);

    const cpuf = try std.fmt.allocPrint(util.gpa, "-c", .{});
    defer util.gpa.free(cpuf);
    try args.append(cpuf);
    const cpuv = try std.fmt.allocPrint(util.gpa, "50", .{});
    defer util.gpa.free(cpuv);
    try args.append(cpuv);

    const interactivef = try std.fmt.allocPrint(util.gpa, "-i", .{});
    defer util.gpa.free(interactivef);
    try args.append(interactivef);

    const persistf = try std.fmt.allocPrint(util.gpa, "-p", .{});
    defer util.gpa.free(persistf);
    try args.append(persistf);

    const helpf = try std.fmt.allocPrint(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

    log.debug = false;
    const debugf = try std.fmt.allocPrint(util.gpa, "-d", .{});
    defer util.gpa.free(debugf);
    try args.append(debugf);

    const test_tidv = try std.fmt.allocPrint(util.gpa, "1", .{});
    defer util.gpa.free(test_tidv);
    try args.append(test_tidv);

    var flags = try parse_cmd_args(args.items);
    defer flags.args.deinit();

    try expect(flags.cpu_limit.? == 50);
    try expect(flags.memory_limit.? == 20_000);
    try expect(flags.interactive.?);
    try expect(flags.persist.?);
    try expect(flags.help);
    try expect(log.debug);
    try expect(flags.args.ids.?[0] == 1);
}

test "No id passed" {
    std.debug.print("No id passed\n", .{});
    const args = try util.gpa.alloc([]u8, 0);
    defer util.gpa.free(args);

    const flags = parse_cmd_args(args);

    try expect(flags == error.MissingTaskId);
}
