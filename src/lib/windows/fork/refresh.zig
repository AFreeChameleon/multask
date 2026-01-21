const std = @import("std");
const libc = @import("../../c.zig").libc;
const ChildProcess = std.process.Child;

const t = @import("../../task/index.zig");
const Task = t.Task;

const Stats = @import("../../task/stats.zig").Stats;

const TaskLogger = @import("../../task/logger.zig");

const e = @import("../../error.zig");
const Errors = e.Errors;

const util = @import("../../util.zig");
const log = @import("../../log.zig");

const taskproc = @import("../../task/process.zig");
const Process = taskproc.Process;
const Cpu = taskproc.Cpu;
const ExistingLimits = taskproc.ExistingLimits;
const Monitoring = taskproc.Monitoring;

pub fn monitor_processes(
    task: *Task, job_handle: libc.HANDLE
) Errors!void {
    errdefer {
        if (task.daemon == null) {
            @panic("Failed to kill process");
        }
        taskproc.kill_all(&task.daemon.?) catch @panic("Failed to kill process");
    }
    try inner_monitor_processes(task, job_handle);
}

fn inner_monitor_processes(
    task: *Task, job_handle: libc.HANDLE
) Errors!void {
    var existing_limits: ExistingLimits = ExistingLimits {
        .mem = task.stats.?.memory_limit,
        .cpu = task.stats.?.cpu_limit
    };
    while (true) {
        refresh_processes(task)
            catch |err| switch (err) {
                error.ProcessNotExists => break,
                else => return err
            };

        const stats = try task.files.?.read_file(Stats);
        if (stats != null) {
            task.stats.? = stats.?;
        }

        // Proc limits
        if (task.stats.?.memory_limit != existing_limits.mem or task.stats.?.cpu_limit != existing_limits.cpu) {
            task.process.?.memory_limit = task.stats.?.memory_limit;
            try set_job_limits(job_handle, task.stats.?.memory_limit, task.stats.?.cpu_limit);
            existing_limits.mem = task.stats.?.memory_limit;
            existing_limits.cpu = task.stats.?.cpu_limit;
        }

        std.Thread.sleep(1_000_000_000);
    }
}

fn refresh_processes(task: *Task) Errors!void {
    if (!task.process.?.proc_exists() and !task.process.?.any_proc_child_exists()) {
        return error.ProcessNotExists;
    }

    if (task.stats.?.memory_limit != 0) {
        task.process.?.memory_limit = task.stats.?.memory_limit;
        // Manual check for memory limit because windows' mem limit doesn't react quick and leaves zombie processes
        try taskproc.check_memory_limit_within_limit(&task.process.?);
    }
    try task.process.?.monitor_stats();
}

pub fn set_job_limits(
    job_handle: libc.HANDLE,
    mem_limit: util.MemLimit,
    cpu_limit: util.CpuLimit
) Errors!void {
    if (mem_limit == 0) {
        try remove_mem_limit(job_handle);
    } else {
        try set_mem_limit(job_handle, mem_limit);
    }

    if (cpu_limit == 0) {
        try remove_cpu_limit(job_handle);
    } else {
        try set_cpu_limit(job_handle, cpu_limit);
    }
}

fn remove_mem_limit(
    job_handle: libc.HANDLE
) Errors!void {
    var limit_info = std.mem.zeroes(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    if (libc.QueryInformationJobObject(
        job_handle,
        libc.JobObjectExtendedLimitInformation,
        &limit_info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        null
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.FailedToSaveProcesses;
    }

    // If the JOB_OBJECT_LIMIT_PROCESS_MEMORY is not there
    if (
        (limit_info.BasicLimitInformation.LimitFlags & libc.JOB_OBJECT_LIMIT_PROCESS_MEMORY) == 0
    ) {
        return;
    }

    limit_info.BasicLimitInformation.LimitFlags ^= libc.JOB_OBJECT_LIMIT_PROCESS_MEMORY;
    limit_info.ProcessMemoryLimit = 0;
    if (libc.SetInformationJobObject(
        job_handle,
        libc.JobObjectExtendedLimitInformation,
        &limit_info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.ForkFailed;
    }
}

fn set_mem_limit(
    job_handle: libc.HANDLE,
    mem_limit: util.MemLimit
) Errors!void {
    var limit_info = std.mem.zeroes(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    if (libc.QueryInformationJobObject(
        job_handle,
        libc.JobObjectExtendedLimitInformation,
        &limit_info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        null
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.FailedToSaveProcesses;
    }

    // If the JOB_OBJECT_LIMIT_PROCESS_MEMORY is not there
    if (
        (limit_info.BasicLimitInformation.LimitFlags & libc.JOB_OBJECT_LIMIT_PROCESS_MEMORY) == 0
    ) {
        limit_info.BasicLimitInformation.LimitFlags ^= libc.JOB_OBJECT_LIMIT_PROCESS_MEMORY;
    }

    limit_info.ProcessMemoryLimit = mem_limit;
    if (libc.SetInformationJobObject(
        job_handle,
        libc.JobObjectExtendedLimitInformation,
        &limit_info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.ForkFailed;
    }
}

fn remove_cpu_limit(
    job_handle: libc.HANDLE,
) Errors!void {
    var cpu_limit_info = std.mem.zeroes(libc.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION);
    if (libc.QueryInformationJobObject(
        job_handle,
        libc.JobObjectCpuRateControlInformation,
        &cpu_limit_info,
        @sizeOf(libc.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION),
        null
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.FailedToGetProcessChildren;
    }

    // If the JOB_OBJECT_CPU_RATE_CONTROL_ENABLE is not there
    if (
        cpu_limit_info.ControlFlags & libc.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE == 0 and
        cpu_limit_info.ControlFlags & libc.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP == 0
    ) {
        return;
    }

    if (
        cpu_limit_info.ControlFlags & libc.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE == libc.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE
    ) {
        cpu_limit_info.ControlFlags ^= libc.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE;
    }
    if (
        cpu_limit_info.ControlFlags & libc.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP == libc.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP
    ) {
        cpu_limit_info.ControlFlags ^= libc.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
    }

    if (libc.SetInformationJobObject(
        job_handle,
        libc.JobObjectCpuRateControlInformation,
        &cpu_limit_info,
        @sizeOf(libc.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION)
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.ForkFailed;
    }
}

fn set_cpu_limit(
    job_handle: libc.HANDLE,
    cpu_limit: util.CpuLimit
) Errors!void {
    var cpu_limit_info = std.mem.zeroes(libc.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION);
    if (libc.QueryInformationJobObject(
        job_handle,
        libc.JobObjectCpuRateControlInformation,
        &cpu_limit_info,
        @sizeOf(libc.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION),
        null
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.FailedToGetProcessChildren;
    }

    // If the JOB_OBJECT_CPU_RATE_CONTROL_ENABLE is not there
    if (
        cpu_limit_info.ControlFlags & libc.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE == 0
    ) {
        cpu_limit_info.ControlFlags |= libc.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE;
    }
    if (
        cpu_limit_info.ControlFlags & libc.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP == 0
    ) {
        cpu_limit_info.ControlFlags |= libc.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
    }

    cpu_limit_info.unnamed_0 = .{
        .CpuRate = @intCast(cpu_limit * 100)
    };

    if (libc.SetInformationJobObject(
        job_handle,
        libc.JobObjectCpuRateControlInformation,
        &cpu_limit_info,
        @sizeOf(libc.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION)
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.ForkFailed;
    }
}
