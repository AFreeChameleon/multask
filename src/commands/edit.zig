const std = @import("std");
const unix_fork = @import("../lib/unix/fork.zig");

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
    namespace: ?[]const u8,
    memory_limit: util.MemLimit,
    cpu_limit: util.CpuLimit,
    help: bool,
    ids: []const TaskId
};

pub fn run() Errors!void {
    const flags = try parse_args();
    if (flags.help) return;

    try util.validate_flags(.{
        .memory_limit = flags.memory_limit,
        .cpu_limit = flags.cpu_limit
    });

    var namespaces = try task.TaskManager.get_namespaces();

    for (flags.ids) |id| {
        // Files are closed in the forked process
        var new_task = try task.TaskManager.get_task_from_id(
            id
        );
        if (flags.memory_limit != 0) {
            new_task.stats.memory_limit = flags.memory_limit;
        }
        if (flags.cpu_limit != 0) {
            new_task.stats.cpu_limit = flags.cpu_limit;
        }
        try new_task.files.write_stats_file(new_task.stats);

        if (flags.namespace != null) {
            var key_itr = namespaces.keyIterator();
            while (key_itr.next()) |ns_name| {
                const ns_ids = namespaces.get(ns_name.*);
                if (ns_ids == null or ns_ids.?.len == 0) continue;

                var ns_ids_list = std.ArrayList(TaskId).fromOwnedSlice(util.gpa, ns_ids.?);
                defer ns_ids_list.deinit();

                const ns_idx = std.mem.indexOfScalar(TaskId, ns_ids_list.items, id);
                if (ns_idx != null) {
                    // If task id is in namespace VV
                    if (std.mem.eql(u8, flags.namespace.?, ns_name.*)) {
                        try log.printwarn("Task is already in this namespace.", .{});
                        continue;
                    }
                    // Do a removal here because we're swapping the tid to
                    // another namespace
                    _ = ns_ids_list.orderedRemove(ns_idx.?);
                    namespaces.put(
                        ns_name.*,
                        ns_ids_list.toOwnedSlice()
                            catch |err| return e.verbose_error(err, error.FailedToEditNamespace)
                    ) catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
                    continue;
                }

                if (std.mem.eql(u8, flags.namespace.?, ns_name.*)) {
                    ns_ids_list.append(id)
                        catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
                    namespaces.put(
                        ns_name.*,
                        ns_ids_list.toOwnedSlice()
                            catch |err| return e.verbose_error(err, error.FailedToEditNamespace)
                    ) catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
                }
            }
        }

        try log.printsucc("Task edited with id {d}.", .{new_task.id});
    }

    if (flags.namespace != null) {
        try task.TaskManager.save_namespaces(&namespaces);
    }
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("c:m:n:dh");
    var flags = Flags {
        .memory_limit = 0,
        .cpu_limit = 0,
        .help = false,
        .namespace = null,
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
    .{"Can change resource limits of tasks by task id or namespace"},
    .{"Usage: mlt edit -m 40M -c 20 -n ns_two 1 2 ns_one"},
    .{"flags:"},
    .{"", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "-n [text]", "Set namespace for the process"},
    .{"", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"For more, run `mlt help`"},
};
