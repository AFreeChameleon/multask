const std = @import("std");
const ChildProcess = std.process.Child;

const Stats = @import("../task/stats.zig").Stats;
const t = @import("../task/index.zig");
const Task = t.Task;
const TaskLogger = @import("../task/logger.zig");
const e = @import("../error.zig");
const util = @import("../util.zig");
const Errors = e.Errors;
const log = @import("../log.zig");

const taskproc = @import("../task/process.zig");
const Process = taskproc.Process;
const Cpu = taskproc.Cpu;
const ExistingLimits = taskproc.ExistingLimits;
const Monitoring = taskproc.Monitoring;

pub fn monitor_processes(
    task: *Task,
    sleep_condition: *std.Thread.Condition,
    sleep_mutex: *std.Thread.Mutex,
) Errors!void {
    errdefer {
        if (task.daemon == null) {
            @panic("Failed to kill process");
        }
        taskproc.kill_all(&task.daemon.?) catch @panic("Failed to kill process");
    }
    try inner_monitor_processes(task, sleep_condition, sleep_mutex);
}

fn inner_monitor_processes(
    task: *Task,
    sleep_condition: *std.Thread.Condition,
    sleep_mutex: *std.Thread.Mutex,
) Errors!void {
    const cpu_limit = task.stats.?.cpu_limit;
    var cpu_times: ?CpuLimitTimes = if (cpu_limit != 0)
        get_cpu_limit_times(cpu_limit) else null;
    const existing_limits = ExistingLimits {
        .mem = task.stats.?.memory_limit,
        .cpu = task.stats.?.cpu_limit
    };
    while (true) {
        refresh_processes(task)
            catch |err| switch (err) {
                error.ProcessNotExists => break,
                else => return err
            };
        if (try update_limits(task, &existing_limits)) |times| {
            cpu_times = times;
        }
        if (cpu_times != null and cpu_times.?.sleep != 0) {
            try task.process.?.set_all_status(.Sleep);
            sleep_control(cpu_times.?.sleep, sleep_condition, sleep_mutex);
            try task.process.?.set_all_status(.Active);
            sleep_control(cpu_times.?.alive, sleep_condition, sleep_mutex);
        } else {
            sleep_control(1_000_000_000, sleep_condition, sleep_mutex);
        }
    }
}

/// Uses a thread condition because the process could die at any second and
/// and this is a way to cut the sleep early compared to a 
/// std.Thread.sleep. Time is in nanoseconds
fn sleep_control(
    time: u64,
    sleep_condition: *std.Thread.Condition,
    sleep_mutex: *std.Thread.Mutex,
) void {
    sleep_mutex.lock();
    // The only error is when the timeout hits the full duration which is not
    // an error for us.
    sleep_condition.timedWait(sleep_mutex, time) catch {};
    sleep_mutex.unlock();
}

fn refresh_processes(task: *Task) Errors!void {
    if (!task.process.?.proc_exists()) {
        const saved_procs = try taskproc.get_running_saved_procs(&task.process.?);
        defer util.gpa.free(saved_procs);
        if (saved_procs.len == 0) {
            return error.ProcessNotExists;
        }
    }
    try task.process.?.monitor_stats();
}

fn update_limits(task: *Task, existing_limits: *const ExistingLimits) Errors!?CpuLimitTimes {
    // Refresh process stats
    const stats = try task.files.?.read_file(Stats);
    if (stats == null) {
        return error.FailedToGetTaskStats;
    }
    task.stats.?.deinit();
    task.stats = stats.?;
    if (task.stats.?.memory_limit != existing_limits.mem) {
        try log.printdebug("Refresh lim {d} {d}", .{existing_limits.mem, task.stats.?.memory_limit});
        try task.process.?.limit_memory(task.stats.?.memory_limit);
    }
    if (task.stats.?.cpu_limit != existing_limits.cpu) {
        try log.printdebug("CPU Refresh lim {d} {d}", .{existing_limits.cpu, task.stats.?.cpu_limit});
        const new_cpu_times = get_cpu_limit_times(task.stats.?.cpu_limit);
        return new_cpu_times;
    }
    return null;
}

const CpuLimitTimes = struct {
    alive: u32,
    sleep: u32
};
fn get_cpu_limit_times(cpu_limit: util.CpuLimit) CpuLimitTimes {
    const fl_cpu_limit: f32 = @as(f32, @floatFromInt(cpu_limit));
    const nanosecs_in_second: f32 = 1_000_000_000.0; // 1 second in nanoseconds
    const fl_running_time: f32 = nanosecs_in_second * (fl_cpu_limit / 100);
    const fl_idle_time: f32 = nanosecs_in_second - fl_running_time;
    return CpuLimitTimes {
        .alive = @intFromFloat(fl_running_time),
        .sleep = @intFromFloat(fl_idle_time)
    };
}

