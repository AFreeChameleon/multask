const std = @import("std");
const expect = std.testing.expect;
const unix_fork = @import("../lib/unix/fork.zig");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const p = @import("../lib/task/process.zig");
const Process = p.Process;

const tm = @import("../lib/task/manager.zig");
const TaskManager = tm.TaskManager;
const Tasks = tm.Tasks;

const ReadProcess = @import("../lib/task/file.zig").ReadProcess;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const TaskArgs = util.TaskArgs;

const log = @import("../lib/log.zig");
const parse = @import("../lib/args/parse.zig");

const main = @import("../lib/table/main.zig");
const stats = @import("../lib/table/stats.zig");

const cpu = @import("../lib/linux/cpu.zig");
const window = @import("../lib/window.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    watch: bool,
    all: bool,
    help: bool,
    stats: bool,
    args: TaskArgs,
};

pub fn run(argv: [][]u8) Errors!void {
    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    var flags = try parse_cmd_args(argv, &tasks);
    defer flags.args.deinit();

    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    if (flags.stats) {
        try run_stats_table(&flags);
    } else {
        try run_main_table(&flags);
    }
}

fn run_stats_table(flags: *Flags) Errors!void {
    const out = std.io.getStdOut();
    var buf = std.io.bufferedWriter(out.writer());
    var bw = buf.writer();

    var table = try stats.init_table();
    defer table.deinit();

    const ids = try check_taskids(flags.args);
    defer util.gpa.free(ids);
    std.mem.sort(TaskId, ids, {}, comptime std.sort.asc(TaskId));
    var has_corrupted_rows = try stats.set_stats_table(&table, ids);
    try stats.print_table(&table, &bw);

    buf.flush()
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    if (!flags.watch) {
        if (has_corrupted_rows) {
            try log.printerr(error.CorruptedTask);
        }
        stats.free_table_rows(&table);
        return;
    }

    while (true) {
        std.Thread.sleep(1_000_000_000);
        // Building the new table to put over the original one because
        // on windows the blinking juuust bad enough and gives me motion sickness
        var new_table = try stats.init_table();
        has_corrupted_rows = try stats.set_stats_table(&new_table, ids);
        if (has_corrupted_rows) {
            try log.printerr(error.CorruptedTask);
            break;
        }

        table.clear(&bw)
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

        stats.free_table_rows(&table);
        table.deinit();

        try stats.print_table(&new_table, &bw);
        table = new_table;

        buf.flush()
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
}


fn run_main_table(flags: *Flags) Errors!void {
    const out = std.io.getStdOut();
    var buf = std.io.bufferedWriter(out.writer());
    var bw = buf.writer();

    var table = try main.init_table();

    const ids = try check_taskids(flags.args);
    defer util.gpa.free(ids);
    std.mem.sort(TaskId, ids, {}, comptime std.sort.asc(TaskId));
    var has_corrupted_rows = try main.set_main_table(&table, ids, flags.all);

    try main.print_table(&table, &bw);
    buf.flush()
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    if (!flags.watch) {
        if (has_corrupted_rows) {
            try log.printerr(error.CorruptedTask);
        }
        main.free_table_rows(&table);
        table.deinit();
        return;
    }


    while (true) {
        std.Thread.sleep(1_000_000_000);
        // Building the new table to put over the original one because
        // on windows the blinking juuust bad enough and gives me motion sickness
        var new_table = try main.init_table();

        has_corrupted_rows = try main.set_main_table(&new_table, ids, flags.all);
        if (has_corrupted_rows) {
            try log.printerr(error.CorruptedTask);
            break;
        }

        table.clear(&bw)
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

        main.free_table_rows(&table);
        table.deinit();

        try main.print_table(&new_table, &bw);
        table = new_table;

        buf.flush()
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
}

// Removes any old tasks
fn check_taskids(targs: TaskArgs) Errors![]TaskId {
    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    if (!targs.parsed) {
        return util.gpa.dupe(TaskId, tasks.task_ids) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    var new_ids = std.ArrayList(TaskId).init(util.gpa);
    defer new_ids.deinit();

    // namespace ids + regular selected ids
    var selected_id_list = std.ArrayList(TaskId).init(util.gpa);
    defer selected_id_list.deinit();
    selected_id_list.appendSlice(targs.ids.?) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    if (targs.namespaces != null) {
        selected_id_list.appendSlice(try TaskManager.get_ids_from_namespaces(tasks.namespaces, targs.namespaces.?)) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    const selected_ids = try util.unique_array(TaskId, selected_id_list.items);
    defer util.gpa.free(selected_ids);

    for (selected_ids) |tid| {
        if (std.mem.indexOfScalar(TaskId, tasks.task_ids, tid) != null) {
            new_ids.append(tid) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        }
    }
    const owned_new_ids = new_ids.toOwnedSlice() catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    return owned_new_ids;
}

fn parse_cmd_args(argv: [][]u8, tasks: *Tasks) Errors!Flags {
    var flags = Flags{ .watch = false, .all = false, .help = false, .args = TaskArgs{}, .stats = false };
    var pflags = util.gpa.alloc(parse.Flag, 6)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    defer util.gpa.free(pflags);
    pflags[0] = parse.Flag{ .name = 'a', .type = .static };
    pflags[1] = parse.Flag{ .name = 'w', .type = .static };
    pflags[2] = parse.Flag{ .name = 'f', .type = .static };
    pflags[3] = parse.Flag{ .name = 'h', .type = .static };
    pflags[4] = parse.Flag{ .name = 'd', .type = .static };
    pflags[5] = parse.Flag{ .name = 's', .type = .static, .long_name = "stats" };

    const vals = try parse.parse_args(argv, pflags);
    defer util.gpa.free(vals);

    for (pflags) |flag| {
        if (!flag.exists) {
            continue;
        }
        switch (flag.name) {
            'w', 'f' => flags.watch = true,
            'a' => flags.all = true,
            'h' => flags.help = true,
            's' => flags.stats = true,
            'd' => log.enable_debug(),
            else => continue,
        }
    }
    if (vals.len == 0) {
        flags.args.ids = util.gpa.dupe(TaskId, tasks.task_ids) catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
        std.mem.sort(TaskId, flags.args.ids.?, {}, comptime std.sort.asc(TaskId));
        return flags;
    }
    const parsed_args = try util.parse_cmd_vals(vals, tasks);
    flags.args = parsed_args;
    return flags;
}

pub const help_rows = .{
    .{"mlt ls"},
    .{"Gets stats and resource usage of tasks"},
    .{"Usage: mlt ls -w -a [task ids or namespaces OPTIONAL]"},
    .{"Flags:"},
    .{ "", "-w, -f", "", "", "Updates tables every 2 seconds." },
    .{ "", "-a", "", "", "Show all child processes under each task." },
    .{ "", "-s", "", "", "Show stats for each task e.g resource limits and flags." },
    .{""},
    .{"A task's different states are:"},
    .{ "Running", "", "The process is running" },
    .{ "Stopped", "", "The task is stopped" },
    .{ "Detached", "The main process in the task has stopped, but it has child processes that are still running." },
    .{ "Headless", "The main process is running, but the multask daemon is not. This is bad and the task should be restarted." },
    .{""},
};

test "commands/ls.zig" {
    std.debug.print("\n--- commands/ls.zig ---\n", .{});
}

test "Parse ls command args" {
    std.debug.print("Parse ls command args\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const watchf = try std.fmt.allocPrint(util.gpa, "-w", .{});
    defer util.gpa.free(watchf);
    try args.append(watchf);

    const allf = try std.fmt.allocPrint(util.gpa, "-a", .{});
    defer util.gpa.free(allf);
    try args.append(allf);

    const helpf = try std.fmt.allocPrint(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

    log.debug = false;
    const debugf = try std.fmt.allocPrint(util.gpa, "-d", .{});
    defer util.gpa.free(debugf);
    try args.append(debugf);

    const statsf = try std.fmt.allocPrint(util.gpa, "--stats", .{});
    defer util.gpa.free(statsf);
    try args.append(statsf);

    const test_tidv = try std.fmt.allocPrint(util.gpa, "1", .{});
    defer util.gpa.free(test_tidv);
    try args.append(test_tidv);

    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var all_task_ids = [_]TaskId{1, 2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };

    var flags = try parse_cmd_args(args.items, &tasks);
    defer flags.args.deinit();

    try expect(flags.watch);
    try expect(flags.all);
    try expect(flags.help);
    try expect(flags.stats);
    try expect(log.debug);
    try expect(flags.args.ids.?[0] == 1);
}
