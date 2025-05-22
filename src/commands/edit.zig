const std = @import("std");
const expect = std.testing.expect;
const unix_fork = @import("../lib/unix/fork.zig");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const m = @import("../lib/task/manager.zig");
const TaskManager = m.TaskManager;
const TNamespaces = m.TNamespaces;
const Stats = @import("../lib/task/stats.zig").Stats;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    namespace: ?[]const u8,
    memory_limit: util.MemLimit,
    cpu_limit: util.CpuLimit,
    help: bool,
    args: util.TaskArgs
};

pub fn run(argv: [][]u8) Errors!void {
    var flags = try parse_cmd_args(argv);
    defer flags.args.deinit();

    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    try util.validate_flags(.{
        .memory_limit = flags.memory_limit,
        .cpu_limit = flags.cpu_limit
    });

    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();

    for (flags.args.ids.?) |id| {
        // Files are closed in the forked process
        var new_task = Task.init(id);
        defer new_task.deinit();
        try TaskManager.get_task_from_id(
            &new_task
        );
        if (flags.memory_limit != 0) {
            new_task.stats.memory_limit = flags.memory_limit;
        }
        if (flags.cpu_limit != 0) {
            new_task.stats.cpu_limit = flags.cpu_limit;
        }
        try new_task.files.write_file(Stats, new_task.stats);

        if (flags.namespace != null) {
            // Need a clone because putting it in the namespaces
            try swap_namespace(
                &tasks.namespaces,
                id,
                flags.namespace.?
            );
        }

        try log.printsucc("Task edited with id {d}.", .{new_task.id});
    }

    if (flags.namespace != null) {
        try TaskManager.save_tasks(tasks);
    }
}

fn swap_namespace(ns: *TNamespaces, task_id: TaskId, ns_name: []const u8) Errors!void {
    const new_ns = try util.strdup(ns_name, error.FailedToEditNamespace);
    var itr = ns.iterator();
    while (itr.next()) |entry| {
        if (std.mem.indexOfScalar(TaskId, entry.value_ptr.*, task_id) != null) {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, new_ns, key)) {
                util.gpa.free(new_ns);
                return;
            }
            const old_nskv = ns.fetchRemove(entry.key_ptr.*);
            const tid_arr = old_nskv.?.value;
            var f_oldv = util.gpa.alloc(TaskId, tid_arr.len - 1)
                catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
            var idx: usize = 0;
            for (tid_arr) |v| {
                if (v == task_id) {
                    continue;
                }
                f_oldv[idx] = v;
                idx += 1;
            }
            util.gpa.free(tid_arr);
            ns.put(key, f_oldv)
                catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
            break;
        }
    }
    const new_kv = ns.fetchRemove(new_ns);
    if (new_kv == null) {
        const new_val = util.gpa.alloc(TaskId, 1)
            catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
        new_val[0] = task_id;
        ns.put(new_ns, new_val)
            catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
    } else {
        var f_newv = util.gpa.alloc(TaskId, new_kv.?.value.len + 1)
            catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
        for (new_kv.?.value, 0..) |v, i| {
            f_newv[i] = v;
        }
        f_newv[f_newv.len - 1] = task_id;
        util.gpa.free(new_kv.?.value);
        util.gpa.free(new_ns);
        ns.put(new_kv.?.key, f_newv)
            catch |err| return e.verbose_error(err, error.FailedToEditNamespace);
    }
}

fn parse_cmd_args(argv: [][]u8) Errors!Flags {
    var flags = Flags {
        .memory_limit = 0,
        .cpu_limit = 0,
        .help = false,
        .namespace = null,
        .args = undefined
    };
    var pflags = util.gpa.alloc(parse.Flag, 5)
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
        .name = 'd',
        .type = .static
    };
    pflags[3] = parse.Flag {
        .name = 'h',
        .type = .static
    };
    pflags[4] = parse.Flag {
        .name = 'n',
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
                flags.namespace = flag.value;
            },
            'h' => flags.help = true,
            'd' => log.enable_debug(),
            else => return error.InvalidOption
        }
    }
    flags.args = try util.parse_cmd_vals(vals);
    if (vals.len == 0) {
        flags.args.deinit();
        return error.MissingTaskId;
    }
    return flags;
}

const help_rows  = .{
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

test "commands/edit.zig" {
    std.debug.print("\n--- commands/edit.zig ---\n", .{});
}

test "Parse edit command args" {
    std.debug.print("Parse edit command args\n", .{});
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

    const namespacev = try std.fmt.allocPrintZ(util.gpa, "testone", .{});
    defer util.gpa.free(namespacev);
    try args.append(namespacev);

    const helpf = try std.fmt.allocPrintZ(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

    log.debug = false;
    const debugf = try std.fmt.allocPrintZ(util.gpa, "-d", .{});
    defer util.gpa.free(debugf);
    try args.append(debugf);

    const tid = try std.fmt.allocPrintZ(util.gpa, "1", .{});
    defer util.gpa.free(tid);
    try args.append(tid);

    var flags = try parse_cmd_args(args.items);
    defer flags.args.deinit();

    try expect(flags.cpu_limit == 50);
    try expect(flags.memory_limit == 20_000);
    try expect(std.mem.eql(u8, flags.namespace.?, "testone"));
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
