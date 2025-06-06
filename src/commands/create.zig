const std = @import("std");
const expect = std.testing.expect;
const builtin = @import("builtin");
const t = @import("../lib/task/index.zig");

const TaskManager = @import("../lib/task/manager.zig").TaskManager;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    memory_limit: util.MemLimit,
    cpu_limit: util.CpuLimit,
    interactive: bool,
    persist: bool,
    namespace: ?[]const u8,
    help: bool,
    command: []const u8
};

pub fn run(argv: [][]u8) Errors!void {
    const flags = try parse_cmd_args(argv);

    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    // Files are closed in the forked process
    var new_task = try TaskManager.add_task(
        flags.command,
        flags.cpu_limit,
        flags.memory_limit,
        flags.namespace,
        flags.persist
    );
    defer new_task.deinit();

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

    try log.printsucc("Task started with id {d}.", .{new_task.id});
}

fn parse_cmd_args(argv: [][]u8) Errors!Flags {
    var flags = Flags {
        .memory_limit = 0,
        .cpu_limit = 0,
        .interactive = false,
        .persist = false,
        .help = false,
        .namespace = null,
        .command = undefined
    };
    var pflags = util.gpa.alloc(parse.Flag, 7)
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
        .type = .static
    };
    pflags[3] = parse.Flag {
        .name = 'p',
        .type = .static
    };
    pflags[4] = parse.Flag {
        .name = 'd',
        .type = .static
    };
    pflags[5] = parse.Flag {
        .name = 'h',
        .type = .static
    };
    pflags[6] = parse.Flag {
        .name = 'n',
        .type = .value
    };

    const vals = try parse.parse_args(argv, pflags);
    defer {
        util.gpa.free(vals);
    }

    for (pflags) |flag| {
        if (!flag.exists) {
            continue;
        }
        switch (flag.name) {
            'c' => {
                flags.cpu_limit = std.fmt.parseInt(util.CpuLimit, flag.value.?, 10)
                    catch return error.CpuLimitValueInvalid;
            },
            'm' => {
                flags.memory_limit = std.fmt.parseIntSizeSuffix(flag.value.?, 10)
                    catch |err| switch (err) {
                        error.InvalidCharacter => {
                            return error.MemoryLimitValueInvalid;
                        },
                        else => return error.ParsingCommandArgsFailed
                    };
            },
            'n' => {
                if (!util.is_alphabetic(flag.value.?)) {
                    return error.NamespaceValueInvalid;
                }
                if (std.mem.eql(u8, flag.value.?, "all")) {
                    return error.NamespaceValueCantBeAll;
                }
                
                flags.namespace = if (flag.value == null) null else
                    try util.strdup(flag.value.?, error.ParsingCommandArgsFailed);
            },
            'i' => flags.interactive = true,
            'h' => flags.help = true,
            'p' => flags.persist = true,
            'd' => log.enable_debug(),
            else => return error.InvalidOption
        }
    }
    if (vals.len == 0) {
        return error.CommandNotExists;
    }
    flags.command = std.mem.join(util.gpa, " ", vals)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    return flags;
}

const help_rows = .{
    .{"Creates and starts a task by entering a command."},
    .{"Usage: mlt create -m 20M -c 50 -n ns_one -i -p \"ping google.com\""},
    .{"flags:"},
    .{"", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "-n [text]", "Set namespace for the process"},
    .{"", "-i", "", "Interactive mode (can use aliased commands on your environment)"},
    .{"", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"For more, run `mlt help`"},
};

test "commands/create.zig" {
    std.debug.print("\n--- commands/create.zig ---\n", .{});
}

test "Parse create command args" {
    std.debug.print("Parse create command args\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const memf = try std.fmt.allocPrintZ(util.gpa, "-m", .{});
    defer util.gpa.free(memf);
    try args.append(memf);
    const memv = try std.fmt.allocPrintZ(util.gpa, "20k", .{});
    defer util.gpa.free(memv);
    try args.append(memv);

    const cpuf = try std.fmt.allocPrintZ(util.gpa, "-c", .{});
    defer util.gpa.free(cpuf);
    try args.append(cpuf);

    const cpuv = try std.fmt.allocPrintZ(util.gpa, "50", .{});
    defer util.gpa.free(cpuv);
    try args.append(cpuv);

    const namespacef = try std.fmt.allocPrintZ(util.gpa, "-n", .{});
    defer util.gpa.free(namespacef);
    try args.append(namespacef);

    const namespacev = try std.fmt.allocPrint(util.gpa, "testone", .{});
    defer util.gpa.free(namespacev);
    try args.append(namespacev);

    const interactivef = try std.fmt.allocPrintZ(util.gpa, "-i", .{});
    defer util.gpa.free(interactivef);
    try args.append(interactivef);

    const persistf = try std.fmt.allocPrintZ(util.gpa, "-p", .{});
    defer util.gpa.free(persistf);
    try args.append(persistf);

    const helpf = try std.fmt.allocPrintZ(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

    log.debug = false;
    const debugf = try std.fmt.allocPrintZ(util.gpa, "-d", .{});
    defer util.gpa.free(debugf);
    try args.append(debugf);

    const command1 = try std.fmt.allocPrintZ(util.gpa, "echo", .{});
    defer util.gpa.free(command1);
    try args.append(command1);
    const command2 = try std.fmt.allocPrintZ(util.gpa, "hi", .{});
    defer util.gpa.free(command2);
    try args.append(command2);

    const flags = try parse_cmd_args(args.items);
    defer util.gpa.free(flags.command);
    defer util.gpa.free(flags.namespace.?);

    try expect(flags.cpu_limit == 50);
    try expect(flags.memory_limit == 20_000);
    try expect(std.mem.eql(u8, flags.namespace.?, "testone"));
    try expect(flags.interactive);
    try expect(flags.persist);
    try expect(flags.help);
    try expect(log.debug);
    try expect(std.mem.eql(u8, flags.command, "echo hi"));
}

test "No command passed" {
    std.debug.print("No command passed\n", .{});
    const args = try util.gpa.alloc([]u8, 0);
    defer util.gpa.free(args);

    const flags = parse_cmd_args(args);

    try expect(flags == error.CommandNotExists);
}
