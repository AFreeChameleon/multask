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

const log = @import("../lib/log.zig");

const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

const Stats = @import("../lib/task/stats.zig").Stats;

pub fn run() Errors!void {
    log.enabled_logging = false;
    try log.printdebug("Starting tasks...", .{});
    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();

    for (tasks.task_ids) |task_id| {
        // Files are closed in the forked process
        var task = Task.init(task_id);
        defer task.deinit();
        try TaskManager.get_task_from_id(&task);

        if (task.stats == null or !task.stats.?.boot) {
            continue;
        }

        if (try TaskManager.task_running(&task)) {
            try log.printdebug("Task with id: {d} already running.", .{task_id});
            continue;
        }

        if (comptime builtin.target.os.tag != .windows) {
            const unix_fork = @import("../lib/unix/fork.zig");
            try unix_fork.run_daemon(&task, .{
                .memory_limit = task.stats.?.memory_limit,
                .cpu_limit = task.stats.?.cpu_limit,
                .interactive = task.stats.?.interactive,
                .persist = task.stats.?.persist,
                .update_envs = false
            });
        } else {
            const windows_fork = @import("../lib/windows/fork.zig");
            try windows_fork.run_daemon(&task, .{
                .memory_limit = task.stats.?.memory_limit,
                .cpu_limit = task.stats.?.cpu_limit,
                .interactive = task.stats.?.interactive,
                .persist = task.stats.?.persist,
                .update_envs = false
            });
            defer task.deinit();
        }
        try log.printdebug("Started task {d}", .{task_id});
    }
}
