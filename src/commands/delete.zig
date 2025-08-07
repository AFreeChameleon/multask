const std = @import("std");

const task = @import("../lib/task/index.zig");
const Task = task.Task;
const TaskId = task.TaskId;
const TaskManager = task.TaskManager;

const Files = @import("../lib/task/file.zig").Files;
const Process = @import("../lib/task/process.zig").Process;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const getopt = @import("../lib/args/getopt.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    help: bool,
    ids: []const TaskId
};

pub fn run() Errors!void {
    var new_taskids = std.ArrayList(TaskId).init(util.gpa);
    defer new_taskids.deinit();

    const flags = try parse_args();
    if (flags.help) return;

    var task_ids = try TaskManager.get_taskids();
    var namespaces = try TaskManager.get_namespaces();
    for (flags.ids) |id| {
        const task_idx = std.mem.indexOf(TaskId, task_ids, &[1]TaskId{id});
        if (task_idx == null) return error.TaskNotExists;
        task_ids[task_idx.?] = -1;

        var new_task = TaskManager.get_task_from_id(
            id
        ) catch |err| {
            if (err == error.CorruptedTask) {
                var corr_task = try init_corrupt_task(id);
                try corr_task.files.delete_files();
                continue;
            } else return error.TaskNotExists;
        };
        if (new_task.process.proc_exists()) {
            try new_task.process.kill_all();
        }
        try new_task.files.delete_files();

        try util.remove_id_from_namespace(id, &namespaces);

        try log.printsucc("Task deleted with id {d}.", .{new_task.id});
    }

    // Saving left over task ids
    for (task_ids) |id| {
        if (id != -1) {
            new_taskids.append(id)
                catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
        }
    }
    const owned_ids = new_taskids.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
    try TaskManager.save_taskids(owned_ids);
    try TaskManager.save_namespaces(&namespaces);
}

fn init_corrupt_task(id: TaskId) Errors!Task {
    var corrupt_task = Task {
        .id = id,
        .namespace = undefined,
        .files = undefined,
        .stats = undefined,
        .process = undefined,
        .resources = undefined
    };
    corrupt_task.files = Files {.task_id = corrupt_task.id};
    const procs = try corrupt_task.files.read_processes_file();
    try log.printdebug("Initialising main process", .{});
    corrupt_task.process = try Process.init(procs.pid, &corrupt_task);
    return corrupt_task;
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("dh");
    var flags = Flags {
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
    .{"Deletes tasks and kills any process that's running under them."},
    .{"Usage: mlt delete 1 2 ns_one"},
    .{""},
    .{"For more, run `mlt help`"},
};
