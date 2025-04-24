const std = @import("std");
const unix_fork = @import("../lib/unix/fork.zig");
const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;
const TaskManager = t.TaskManager;
const file = @import("../lib/file.zig");
const util = @import("../lib/util.zig");
const TaskArgs = util.TaskArgs;
const log = @import("../lib/log.zig");
const getopt = @import("../lib/args/getopt.zig");
const Table = @import("../lib/table/index.zig").Table;
const cpu = @import("../lib/linux/cpu.zig");
const window = @import("../lib/window.zig");
const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    watch: bool,
    all: bool,
    help: bool,
    args: TaskArgs
};

pub fn run() Errors!void {
    var flags = try parse_args();
    if (flags.help) return;

    var tasks = std.AutoHashMap(TaskId, Task).init(util.gpa);
    defer tasks.deinit();

    var table = try Table.init(flags.all);
    try table.append_header();

    for (flags.args.ids.?) |task_id| {
        var task = TaskManager.get_task_from_id(task_id)
            catch {
                try table.add_corrupted_task(task_id);
                continue;
            };
        task.pid = try task.files.read_task_pid_file();
        try task.resources.set_cpu_usage();
        try table.add_task(&task);

        tasks.put(task_id, task)
            catch |err| return e.verbose_error(err, error.FailedSetTaskCache);
    }
    try table.print_table();

    if (!flags.watch) return;

    while (true) {
        std.Thread.sleep(1_000_000_000);
        try table.clear();
        try table.append_header();
        flags.args.ids = try check_taskids(flags.args);

        for (flags.args.ids.?) |task_id| {
            var task: ?Task = tasks.get(task_id);
            if (task == null) {
                task = TaskManager.get_task_from_id(task_id)
                    catch {
                        try table.add_corrupted_task(task_id);
                        continue;
                    };

                try task.?.resources.set_cpu_usage();
                tasks.put(task_id, task.?)
                    catch |err| return e.verbose_error(err, error.FailedSetTaskCache);
            } else {
                try task.?.refresh();

            }
            try task.?.resources.set_cpu_usage();
            try table.add_task(&task.?);
        }

        try table.print_table();
    }

    if (table.corrupted_rows) {
        try log.printerr(error.CorruptedTask);
    }
}

// Removes any old tasks
fn check_taskids(targs: TaskArgs) Errors![]TaskId {
    if (!targs.parsed) {
        return try TaskManager.get_taskids();
    }
    var new_ids = std.ArrayList(TaskId).init(util.gpa);
    defer new_ids.deinit();
    const curr_ids = try TaskManager.get_taskids();
    defer util.gpa.free(curr_ids);

    // namespace ids + regular selected ids
    var selected_id_list = std.ArrayList(TaskId).init(util.gpa);
    defer selected_id_list.deinit();
    selected_id_list.appendSlice(targs.ids.?)
        catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    if (targs.namespaces != null) {
        selected_id_list.appendSlice(try TaskManager.get_ids_from_namespaces(targs.namespaces.?))
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    const selected_ids = try util.unique_array(TaskId, selected_id_list.items);

    for (selected_ids) |tid| {
        if (std.mem.indexOfScalar(TaskId, curr_ids, tid) != null) {
            new_ids.append(tid)
                catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        }
    }
    const owned_new_ids = new_ids.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    return owned_new_ids;
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("wahd");
    var flags = Flags {
        .watch = false,
        .all = false,
        .help = false,
        .args = TaskArgs {}
    };

    var next_val = try opts.next();
    while (!opts.optbreak) {
        if (next_val == null) {
            next_val = try opts.next();
            continue;
        }
        const opt = next_val.?;
        switch (opt.opt) {
            'w' => {
                flags.watch = true;
            },
            'a' => {
                flags.all = true;
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

    if (opts.args() == null or opts.args().?.len == 1) {
        flags.args.ids = try TaskManager.get_taskids();
    } else {
        flags.args = try util.parse_cmd_args(opts.args().?);
    }

    return flags;
}

fn print_help() Errors!void {
    try log.print_help(rows);
}

const rows = .{
    .{"Gets stats and resource usage of tasks"},
    .{"Usage: mlt ls -w -a [task ids or namespaces OPTIONAL]"},
    .{"flags:"},
    .{"", "-w", "Provides updating tables every 2 seconds"},
    .{"", "-a", "Show all child processes"},
    .{""},
    .{"For more, run `mlt help`"},
};
