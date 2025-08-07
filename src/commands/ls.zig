const std = @import("std");
const expect = std.testing.expect;
const unix_fork = @import("../lib/unix/fork.zig");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const p = @import("../lib/task/process.zig");
const Process = p.Process;

const TaskManager  = @import("../lib/task/manager.zig").TaskManager;

const ReadProcess  = @import("../lib/task/file.zig").ReadProcess;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const TaskArgs = util.TaskArgs;

const log = @import("../lib/log.zig");
const parse = @import("../lib/args/parse.zig");
const Table = @import("../lib/table/index.zig").Table;
const cpu = @import("../lib/linux/cpu.zig");
const window = @import("../lib/window.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    watch: bool,
    all: bool,
    help: bool,
    args: TaskArgs,
};

pub fn run(argv: [][]u8) Errors!void {
    var flags = try parse_cmd_args(argv);
    defer flags.args.deinit();

    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    var table = try Table.init(flags.all);
    defer table.deinit();
    try table.append_header();

    for (flags.args.ids.?) |task_id| {
        var task = Task.init(task_id);
        defer task.deinit();
        TaskManager.get_task_from_id(&task)
            catch |err| {
                try log.printdebug("{any}", .{err});
                try table.add_corrupted_task(task_id);
                continue;
            };
        task.resources.set_cpu_usage(&task)
            catch |err| {
                try log.printdebug("{any}", .{err});
                try table.add_corrupted_task(task_id);
                continue;
            };
        table.add_task(&task)
            catch |err| {
                try log.printdebug("{any}", .{err});
                try table.add_corrupted_task(task_id);
                continue;
            };
    }
    try table.print_table();

    if (!flags.watch) return;

    while (true) {
        std.Thread.sleep(1_000_000_000);
        // Top & bottom border and separator of header
        var new_table = try Table.init(flags.all);
        try new_table.append_header();
        const ids = try check_taskids(flags.args);
        defer util.gpa.free(ids);

        for (ids) |task_id| {
            var task = Task.init(task_id);
            defer task.deinit();
            TaskManager.get_task_from_id(&task)
                catch |err| {
                    try log.printdebug("{any}", .{err});
                    try table.add_corrupted_task(task_id);
                    continue;
                };
            try task.resources.set_cpu_usage(&task);
            try new_table.add_task(&task);
        }

        try table.clear();
        try new_table.print_table();
        table.deinit();
        table = new_table;
    }

    if (table.corrupted_rows) {
        try log.printerr(error.CorruptedTask);
    }
    table.reset();
}

// Removes any old tasks
fn check_taskids(targs: TaskArgs) Errors![]TaskId {
    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    if (!targs.parsed) {
        return util.gpa.dupe(TaskId, tasks.task_ids)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    var new_ids = std.ArrayList(TaskId).init(util.gpa);
    defer new_ids.deinit();

    // namespace ids + regular selected ids
    var selected_id_list = std.ArrayList(TaskId).init(util.gpa);
    defer selected_id_list.deinit();
    selected_id_list.appendSlice(targs.ids.?)
        catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    if (targs.namespaces != null) {
        selected_id_list.appendSlice(try TaskManager.get_ids_from_namespaces(
                tasks.namespaces, targs.namespaces.?
        )) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    const selected_ids = try util.unique_array(TaskId, selected_id_list.items);
    defer util.gpa.free(selected_ids);

    for (selected_ids) |tid| {
        if (std.mem.indexOfScalar(TaskId, tasks.task_ids, tid) != null) {
            new_ids.append(tid)
                catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        }
    }
    const owned_new_ids = new_ids.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    return owned_new_ids;
}

fn parse_cmd_args(argv: [][]u8) Errors!Flags {
    var flags = Flags {
        .watch = false,
        .all = false,
        .help = false,
        .args = TaskArgs {}
    };
    var pflags = util.gpa.alloc(parse.Flag, 4)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    defer util.gpa.free(pflags);
    pflags[0] = parse.Flag {
        .name = 'a',
        .type = .static
    };
    pflags[1] = parse.Flag {
        .name = 'w',
        .type = .static
    };
    pflags[2] = parse.Flag {
        .name = 'h',
        .type = .static
    };
    pflags[3] = parse.Flag {
        .name = 'd',
        .type = .static
    };

    const vals = try parse.parse_args(argv, pflags);
    defer util.gpa.free(vals);

    for (pflags) |flag| {
        if (!flag.exists) {
            continue;
        }
        switch (flag.name) {
            'w' => flags.watch = true,
            'a' => flags.all = true,
            'h' => flags.help = true,
            'd' => log.enable_debug(),
            else => continue
        }
    }
    if (vals.len == 0) {
        var tasks = try TaskManager.get_tasks();
        defer tasks.deinit();
        flags.args.ids = util.gpa.dupe(TaskId, tasks.task_ids)
            catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
        std.mem.sort(TaskId, flags.args.ids.?, {}, comptime std.sort.asc(TaskId));
        return flags;
    }
    const parsed_args = try util.parse_cmd_vals(vals);
    flags.args = parsed_args;
    return flags;
}

const help_rows = .{
    .{"Gets stats and resource usage of tasks"},
    .{"Usage: mlt ls -w -a [task ids or namespaces OPTIONAL]"},
    .{"flags:"},
    .{"", "-w", "Provides updating tables every 2 seconds"},
    .{"", "-a", "Show all child processes"},
    .{""},
    .{"A task's different states are:"},
    .{"Running", "", "The process is running"},
    .{"Stopped", "", "The task is stopped"},
    .{"Detached", "The main process in the task has stopped, but it has child processes that are still running."},
    .{"Headless", "The main process is running, but the multask daemon is not. This is bad and the task should be restarted."},
    .{""},
    .{"For more, run `mlt help`"},
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

    const test_tidv = try std.fmt.allocPrint(util.gpa, "1", .{});
    defer util.gpa.free(test_tidv);
    try args.append(test_tidv);

    var flags = try parse_cmd_args(args.items);
    defer flags.args.deinit();

    try expect(flags.watch);
    try expect(flags.all);
    try expect(flags.help);
    try expect(log.debug);
    try expect(flags.args.ids.?[0] == 1);
}

