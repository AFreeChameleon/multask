const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const log = @import("../log.zig");

const util = @import("../util.zig");
const Lengths = util.Lengths;

const TaskManager = @import("./manager.zig").TaskManager;

const Process = @import("./process.zig").Process;
const Stats = @import("./stats.zig").Stats;
const Resources = @import("./resources.zig").Resources;
const ReadProcess = @import("./file.zig").ReadProcess;

const f = @import("./file.zig");
const Files = f.Files;

const MainFiles  = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

pub const TaskId = i32;

pub const Task = struct {
    const Self = @This();

    id: TaskId,
    daemon: ?Process = null,
    namespace: ?[]const u8,
    files: ?Files,
    process: ?Process,
    stats: ?Stats,
    resources: ?Resources,

    pub fn init(id: TaskId) Task {
        return Task {
            .id = id,
            .namespace = null,
            .process = null,
            .files = null,
            .stats = null,
            .resources = null
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.stats != null) {
            self.stats.?.deinit();
        }

        if (self.resources != null) {
            self.resources.?.deinit();
        }

        if (self.process != null) {
            self.process.?.deinit();
        }

        if (self.namespace != null) {
            util.gpa.free(self.namespace.?);
        }
    }

    pub fn clone(self: *Self) Errors!Self {
        var new_task: Task = undefined;
        new_task.id = self.id;
        if (self.namespace != null) {
            new_task.namespace = try util.strdup(self.namespace.?, error.CorruptedTask);
        } else {
            new_task.namespace = null;
        }
        if (self.daemon != null) {
            new_task.daemon = try self.daemon.?.clone(&new_task);
        } else {
            new_task.daemon = null;
        }
        if (self.process != null) {
            new_task.process = try self.process.?.clone(&new_task);
        } else {
            new_task.process = null;
        }
        new_task.files = self.files.clone();
        new_task.stats = try self.stats.clone();
        new_task.resources = try self.resources.clone();
        return new_task;
    }

    pub fn refresh(self: *Self) Errors!void {
        var procs = try self.files.read_file(ReadProcess);
        if (procs != null) {
            defer procs.?.deinit();
            self.daemon = Process.init(self, procs.?.task.pid, procs.?.task.starttime);
            if (procs.?.pid != self.process.?.pid) {
                try log.printdebug("Refreshing main process", .{});
                self.process = try Process.init(self, procs.?.pid, procs.?.starttime);
            }
        }

        var stats = try self.files.read_file(Stats);
        if (stats == null) {
            return error.FailedToGetTaskStats;
        } else {
            defer stats.?.deinit();
            self.stats.command = try util.strdup(stats.?.command, error.FailedToGetTaskStats);
            self.stats.cwd = try util.strdup(stats.?.cwd, error.FailedToGetTaskStats);
        }
    }

    pub fn delete(self: *Self) Errors!void {
        var tasks = try TaskManager.get_tasks();
        defer tasks.deinit();

        try self.files.?.delete_files();

        try util.remove_id_from_namespace(self.id, &tasks.namespaces);

        var new_taskids = util.gpa.alloc(TaskId, tasks.task_ids.len - 1)
            catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
        var idx: usize = 0;
        for (tasks.task_ids) |tid| {
            if (tid == self.id) {
                continue;
            }

            new_taskids[idx] = tid;
            idx += 1;
        }
        util.gpa.free(tasks.task_ids);
        tasks.task_ids = new_taskids;
        try TaskManager.save_tasks(tasks);
    }

    pub fn delete_corrupt(task_id: TaskId) Errors!void {
        var tasks = try TaskManager.get_tasks();
        defer tasks.deinit();

        var tasks_dir = MainFiles.get_or_create_tasks_dir()
            catch |err| blk: {
                try log.printdebug("Error: {any}\n", .{err});
                try log.printinfo("Failed to get tasks directory", .{});
                break :blk null;
            };
        if (tasks_dir != null) {
            defer tasks_dir.?.close();

            const string_task_id = std.fmt.allocPrint(util.gpa, "{d}", .{task_id})
                catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
            defer util.gpa.free(string_task_id);

            _ = tasks_dir.?.deleteTree(string_task_id)
                catch |err| blk: {
                    try log.printdebug("Error: {any}\n", .{err});
                    try log.printinfo("Failed to delete task files", .{});
                    break :blk null;
                };
        }


        _ = util.remove_id_from_namespace(task_id, &tasks.namespaces)
            catch |err| blk: {
                try log.printdebug("Error: {any}\n", .{err});
                try log.printinfo("Failed to remove id from namespace", .{});
                break :blk null;
            };

        var new_taskids = util.gpa.alloc(TaskId, tasks.task_ids.len - 1)
            catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
        var idx: usize = 0;
        for (tasks.task_ids) |tid| {
            if (tid == task_id) {
                continue;
            }

            new_taskids[idx] = tid;
            idx += 1;
        }
        util.gpa.free(tasks.task_ids);
        tasks.task_ids = new_taskids;
        _ = TaskManager.save_tasks(tasks)
            catch |err| blk: {
                try log.printdebug("Error: {any}\n", .{err});
                try log.printinfo("Failed to delete task files", .{});
                break :blk null;
            };
    }
};

