const libc = @import("./lib/c.zig").libc;
const std = @import("std");
const ChildProcess = std.process.Child;

const log = @import("./lib/log.zig");

const e = @import("./lib/error.zig");
const Errors = e.Errors;

const t = @import("./lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const Stats = @import("./lib/task/stats.zig").Stats;

const TaskManager = @import("./lib/task/manager.zig").TaskManager;

const TaskLogger = @import("./lib/task/logger.zig");

const util = @import("./lib/util.zig");

const taskproc = @import("./lib/task/process.zig");
const Process = taskproc.Process;
const ExistingLimits = taskproc.ExistingLimits;

var out_handle_r: libc.HANDLE = std.mem.zeroes(libc.HANDLE);
var out_handle_w: libc.HANDLE = std.mem.zeroes(libc.HANDLE);

var err_handle_r: libc.HANDLE = std.mem.zeroes(libc.HANDLE);
var err_handle_w: libc.HANDLE = std.mem.zeroes(libc.HANDLE);

/// All i shoud be doing is passing in the task id and building the task here
pub fn main() !void {
    const args = try std.process.argsAlloc(util.gpa);
    defer std.process.argsFree(util.gpa, args);

    try log.init();
    if (args.len != 2) {
        try log.printerr(error.NoArgs);
        return;
    }

    if (!util.is_number(args[1])) {
        return error.ForkFailed;
    }

    const task_id = std.fmt.parseInt(TaskId, args[1], 10)
        catch |err| return e.verbose_error(err, error.ForkFailed);

    var task = Task.init(task_id);
    defer task.deinit();
    try TaskManager.get_task_from_id(&task);

    var job_name = std.fmt.allocPrintZ(util.gpa, "Global\\mult-{d}", .{task_id})
        catch |err| return e.verbose_error(err, error.ForkFailed);
    job_name[job_name.len] = 0;
    defer util.gpa.free(job_name);
    const job_handle = try create_job(job_name);
    defer {
        _ = libc.CloseHandle(job_handle);
    }

    task.daemon = try Process.init(&task, util.get_pid(), null);
    while (true) {
        try set_job_limits(job_handle, task.stats.memory_limit, task.stats.cpu_limit);
        // const thread_handle = libc.GetCurrentThread();
        const process_handle = libc.GetCurrentProcess();
        if (libc.AssignProcessToJobObject(job_handle, process_handle) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.ForkFailed;
        }

        const proc_info = try run_command(task.stats.command);
        defer {
            _ = libc.CloseHandle(proc_info.hProcess);
            _ = libc.CloseHandle(proc_info.hThread);
            _ = libc.CloseHandle(out_handle_w);
            _ = libc.CloseHandle(err_handle_w);
        }
        task.process = try Process.init(&task, proc_info.dwProcessId, null);

        try monitor_process(&task, job_handle);
        try taskproc.kill_all(&task.process.?);
        if (!task.stats.persist) {
            break;
        }
        // Persisting with a timeout of 2 seconds
        std.Thread.sleep(2_000_000_000);
    }
}

fn enable_kill_on_job_close(job_handle: ?*anyopaque) Errors!void {
    var info = std.mem.zeroes(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    if (libc.QueryInformationJobObject(
        job_handle,
        libc.JobObjectExtendedLimitInformation,
        &info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        null
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.FailedToSaveProcesses;
    }

    // If it's already set
    if (
        info.BasicLimitInformation.LimitFlags & libc.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE ==
        libc.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    ) {
        return;
    }

    info.BasicLimitInformation.LimitFlags |= libc.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (libc.SetInformationJobObject(
        job_handle,
        libc.JobObjectExtendedLimitInformation,
        &info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.ForkFailed;
    }
}

fn remove_mem_limit(
    job_handle: ?*anyopaque
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
    job_handle: ?*anyopaque,
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
    job_handle: ?*anyopaque,
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
    job_handle: ?*anyopaque,
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

fn set_job_limits(
    job_handle: ?*anyopaque,
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

fn create_job(
    lp_name: []u8
) Errors!?*anyopaque {
    const job = libc.CreateJobObjectA(null, lp_name.ptr);
    if (job == null) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.ForkFailed;
    }
    try enable_kill_on_job_close(job);
    return job;
}

fn run_command(command: []const u8) e.Errors!libc.PROCESS_INFORMATION {
    var saAttr = std.mem.zeroes(libc.SECURITY_ATTRIBUTES);
    saAttr.nLength = @sizeOf(libc.SECURITY_ATTRIBUTES);
    saAttr.bInheritHandle = 1;
    saAttr.lpSecurityDescriptor = null;

    if (libc.CreatePipe(&out_handle_r, &out_handle_w, &saAttr, 0) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }
    if (libc.SetHandleInformation(out_handle_r, libc.HANDLE_FLAG_INHERIT, 0) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }

    if (libc.CreatePipe(&err_handle_r, &err_handle_w, &saAttr, 0) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }
    if (libc.SetHandleInformation(err_handle_r, libc.HANDLE_FLAG_INHERIT, 0) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }

    var proc_info: libc.PROCESS_INFORMATION = std.mem.zeroes(libc.PROCESS_INFORMATION);
    var si: libc.STARTUPINFOEXA = std.mem.zeroes(libc.STARTUPINFOEXA);
    si.StartupInfo.cb = @sizeOf(libc.STARTUPINFOEXA);
    si.StartupInfo.hStdError = err_handle_w;
    si.StartupInfo.hStdOutput = out_handle_w;
    si.StartupInfo.dwFlags |= libc.STARTF_USESTDHANDLES;

    const shell_path = try util.get_shell_path();
    const proc_string = std.fmt.allocPrintZ(util.gpa, "{s} /c {s}", .{shell_path, command})
        catch |err| return e.verbose_error(err, error.CommandFailed);
    defer util.gpa.free(proc_string);

    if (libc.CreateProcessA(
        null, proc_string.ptr, null,
        null, 1,
        0,
        null, null, @as([*c]libc.struct__STARTUPINFOA, @ptrCast(&si.StartupInfo)),
        @as([*c]libc.PROCESS_INFORMATION, @ptrCast(&proc_info))
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }

    return proc_info;
}

fn monitor_process(
    task: *Task,
    job_handle: ?*anyopaque
) e.Errors!void {
    var sec: libc.SECURITY_ATTRIBUTES = std.mem.zeroes(libc.SECURITY_ATTRIBUTES);
    sec.nLength = @sizeOf(libc.SECURITY_ATTRIBUTES);
    sec.bInheritHandle = 1;
    var keep_alive: [2]libc.HANDLE = .{ std.mem.zeroes(libc.HANDLE), std.mem.zeroes(libc.HANDLE) };
    if(libc.CreatePipe(&keep_alive[0], &keep_alive[1], &sec, 0) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }

    var existing_limits: ExistingLimits = ExistingLimits {
        .mem = task.stats.memory_limit,
        .cpu = task.stats.cpu_limit
    };

    // Seeking to end to truncate logs
    const outfile = try task.files.get_file("stdout");
    defer outfile.close();
    const errfile = try task.files.get_file("stderr");
    defer errfile.close();
    outfile.seekFromEnd(0)
        catch |err| return e.verbose_error(err, error.CommandFailed);
    errfile.seekFromEnd(0)
        catch |err| return e.verbose_error(err, error.CommandFailed);
    var stdout_writer = std.io.bufferedWriter(outfile.writer());
    var stderr_writer = std.io.bufferedWriter(errfile.writer());
    var out_new_line = true;
    var err_new_line = true;
    var monitor_time = std.time.nanoTimestamp();
    while (true) {
        var out_queued_bytes: libc.DWORD = 0;
        var err_queued_bytes: libc.DWORD = 0;

        if (libc.PeekNamedPipe(out_handle_r, null, 0, 0, &out_queued_bytes, 0) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.CommandFailed;
        }
        if (out_queued_bytes > 0) {
            var dw_read: libc.DWORD = 0;
            const buf = util.gpa.alloc(u8, out_queued_bytes)
                catch |err| return e.verbose_error(err, error.CommandFailed);
            defer util.gpa.free(buf);
            if (libc.ReadFile(out_handle_r, buf.ptr, out_queued_bytes, &dw_read, null) == 0) {
                try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
                return error.CommandFailed;
            }
            try TaskLogger.write_timed_logs(
                &out_new_line,
                buf,
                @TypeOf(stdout_writer),
                &stdout_writer
            );
        }

        if (libc.PeekNamedPipe(err_handle_r, null, 0, 0, &err_queued_bytes, 0) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.CommandFailed;
        }
        if (err_queued_bytes > 0) {
            var dw_read: libc.DWORD = 0;
            const buf = util.gpa.alloc(u8, err_queued_bytes)
                catch |err| return e.verbose_error(err, error.CommandFailed);
            defer util.gpa.free(buf);
            if (libc.ReadFile(err_handle_r, buf.ptr, err_queued_bytes, &dw_read, null) == 0) {
                try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
                return error.CommandFailed;
            }
            try TaskLogger.write_timed_logs(
                &err_new_line,
                buf,
                @TypeOf(stderr_writer),
                &stderr_writer
            );
        }

        // Making sure every second this is ran
        const current_time = std.time.nanoTimestamp();
        if (current_time > monitor_time + 1_000_000_000) {
            if (task.process == null or !task.process.?.proc_exists()) {
                break;
            }
            
            if (task.stats.memory_limit != 0) {
                task.process.?.memory_limit = task.stats.memory_limit;
                // Manual check for memory limit because windows' mem limit doesn't react quick and leaves zombie processes
                try taskproc.check_memory_limit_within_limit(&task.process.?);
            }
            try task.process.?.monitor_stats();
            monitor_time = current_time;

            const stats = try task.files.read_file(Stats);
            if (stats != null) {
                task.stats = stats.?;
            }
            
            // Proc limits
            if (task.stats.memory_limit != existing_limits.mem or task.stats.cpu_limit != existing_limits.cpu) {
                task.process.?.memory_limit = task.stats.memory_limit;
                try set_job_limits(job_handle, task.stats.memory_limit, task.stats.cpu_limit);
                existing_limits.mem = task.stats.memory_limit;
                existing_limits.cpu = task.stats.cpu_limit;
            }
        }
        if (monitor_time + 1_000_000_000 - current_time < 1_000_000) {
            std.Thread.sleep(@intCast(monitor_time + 1_000_000_000 - current_time));
        } else {
            std.Thread.sleep(1_000_000);
        }
    }
}
