const std = @import("std");
const builtin = @import("builtin");
const task = @import("../lib/task/index.zig");
const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const getopt = @import("../lib/args/getopt.zig");

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

pub fn run() Errors!void {
    const flags = try parse_args();
    if (flags.help) return;

    // Files are closed in the forked process
    var new_task = try task.TaskManager.add_task(
        flags.command,
        flags.cpu_limit,
        flags.memory_limit,
        flags.namespace,
        flags.persist
    );

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

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("n:c:m:ipdh");
    var flags = Flags {
        .memory_limit = 0,
        .cpu_limit = 0,
        .interactive = false,
        .persist = false,
        .help = false,
        .namespace = null,
        .command = undefined
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
                if (!util.is_number(arg)) {
                    return error.CpuLimitValueInvalid;
                }
                flags.cpu_limit = std.fmt.parseInt(util.CpuLimit, arg, 10)
                    catch {
                        return error.CpuLimitValueInvalid;
                    };
            },
            'n' => {
                if (opt.arg == null) {
                    return error.NamespaceValueMissing;
                }
                const arg: []const u8 = opt.arg.?;
                if (!util.is_alphabetic(arg)) {
                    return error.NamespaceValueInvalid;
                }
                if (std.mem.eql(u8, arg, "all")) {
                    return error.NamespaceValueCantBeAll;
                }
                flags.namespace = arg;
            },
            'i' => {
                flags.interactive = true;
            },
            'p' => {
                flags.persist = true;
            },
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
    flags.command = try convert_args_to_command(opts.args().?);

    return flags;
}

fn convert_args_to_command(args: [][*:0]u8) Errors![]const u8 {
    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();
    var command = std.ArrayList(u8).init(arena.allocator());
    defer command.deinit();

    for (args[1..]) |arg_ptr| {
        var ptr_idx: usize = 0;
        while (arg_ptr[ptr_idx] != 0) {
            command.append(arg_ptr[ptr_idx])
                catch return error.ParsingCommandArgsFailed;
            ptr_idx += 1;
        }
        command.append(' ')
            catch return error.ParsingCommandArgsFailed;
    }
    if (command.capacity > util.MAX_TERM_LINE_LENGTH) {
        return error.CommandTooLarge;
    }
    return util.gpa.dupe(u8, command.items)
        catch return error.ParsingCommandArgsFailed;
}

fn print_help() Errors!void {
    try log.print_help(rows);
}

const rows = .{
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
