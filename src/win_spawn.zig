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
const Cpu = taskproc.Cpu;

const taskenv = @import("./lib/task/env.zig");
const procenv = @import("./lib/windows/env.zig");

const read_command_std_output = @import("./lib/windows/fork/logs.zig").read_command_std_output;
const r = @import("./lib/windows/fork/refresh.zig");
const monitor_processes = r.monitor_processes;
const set_job_limits = r.set_job_limits;

var out_handle_r: libc.HANDLE = std.mem.zeroes(libc.HANDLE);
var out_handle_w: libc.HANDLE = std.mem.zeroes(libc.HANDLE);

var err_handle_r: libc.HANDLE = std.mem.zeroes(libc.HANDLE);
var err_handle_w: libc.HANDLE = std.mem.zeroes(libc.HANDLE);

pub fn main() !void {
    // log.enable_debug();
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

    var envs = try taskproc.get_envs(&task, false);
    defer envs.deinit();
    try taskenv.add_multask_taskid_to_map(&envs, task_id);
    const env_block = try procenv.map_to_string(&envs);
    defer util.gpa.free(env_block);

    var job_name = std.fmt.allocPrintZ(util.gpa, "Global\\mult-{d}", .{task_id})
        catch |err| return e.verbose_error(err, error.ForkFailed);
    job_name[job_name.len] = 0;
    defer util.gpa.free(job_name);
    const job_handle = try create_job(job_name);
    defer {
        _ = libc.CloseHandle(job_handle);
    }

    task.daemon = try Process.init(&task, util.get_pid(), null);
    task.resources.?.meta = Cpu.init();
    while (true) {
        try set_job_limits(job_handle, task.stats.?.memory_limit, task.stats.?.cpu_limit);
        const proc_info = try run_command(task.stats.?.command, task.stats.?.cwd, env_block);
        if (libc.AssignProcessToJobObject(job_handle, proc_info.hProcess) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.ForkFailed;
        }
        defer {
            _ = libc.CloseHandle(proc_info.hProcess);
            _ = libc.CloseHandle(proc_info.hThread);
            _ = libc.CloseHandle(out_handle_w);
            _ = libc.CloseHandle(err_handle_w);
        }
        task.process = try Process.init(&task, proc_info.dwProcessId, null);

        try spawn_worker_threads(&task, job_handle, proc_info.hProcess);
        try taskproc.kill_all(&task.process.?);
        if (!task.stats.?.persist) {
            break;
        }
        // Persisting with a timeout of 2 seconds
        std.Thread.sleep(2_000_000_000);
    }
}

fn spawn_worker_threads(
    task: *Task, job_handle: libc.HANDLE, proc_event_handle: libc.HANDLE
) Errors!void {
    const log_thread = std.Thread.spawn(
        .{ .allocator = util.gpa },
        read_command_std_output,
        .{ out_handle_r, err_handle_r, task, proc_event_handle }
    ) catch |err| return e.verbose_error(err, error.FailedToSpawnThread);
    const monitor_thread = std.Thread.spawn(
        .{ .allocator = util.gpa },
        monitor_processes,
        .{ task, job_handle }
    ) catch |err| return e.verbose_error(err, error.FailedToSpawnThread);

    monitor_thread.join();
    log_thread.join();

    try log.printdebug("No more saved processes are alive.", .{});
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
    info.BasicLimitInformation.LimitFlags |= libc.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | libc.JOB_OBJECT_LIMIT_BREAKAWAY_OK;
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

fn set_pipes(saAttr: *libc.SECURITY_ATTRIBUTES) Errors!void {
    const self_pid = std.os.windows.GetCurrentProcessId();
    var buf: [128]u8 = undefined;
    const out_pipe = std.fmt.bufPrint(&buf, "\\\\.\\pipe\\multask-{d}-stdout", .{self_pid})
        catch |err| return e.verbose_error(err, error.CommandFailed);
    out_handle_r = libc.CreateNamedPipeA(
        out_pipe.ptr,
        libc.PIPE_ACCESS_INBOUND | libc.FILE_FLAG_OVERLAPPED,
        libc.PIPE_TYPE_BYTE | libc.PIPE_WAIT,
        1,
        4096,
        4096,
        0,
        null
    );
    if (out_handle_r == libc.INVALID_HANDLE_VALUE) {
        return error.CommandFailed;
    }

    out_handle_w = libc.CreateFileA(
        out_pipe.ptr,
        libc.GENERIC_WRITE,
        0,
        saAttr,
        libc.OPEN_EXISTING,
        libc.FILE_FLAG_WRITE_THROUGH | libc.FILE_FLAG_NO_BUFFERING,
        null
    );
    if (err_handle_w == libc.INVALID_HANDLE_VALUE) {
        return error.CommandFailed;
    }

    const err_pipe = std.fmt.bufPrint(&buf, "\\\\.\\pipe\\multask-{d}-stderr", .{self_pid})
        catch |err| return e.verbose_error(err, error.CommandFailed);
    err_handle_r = libc.CreateNamedPipeA(
        err_pipe.ptr,
        libc.PIPE_ACCESS_INBOUND | libc.FILE_FLAG_OVERLAPPED,
        libc.PIPE_TYPE_BYTE | libc.PIPE_WAIT,
        1,
        4096,
        4096,
        0,
        null
    );
    if (err_handle_r == libc.INVALID_HANDLE_VALUE) {
        return error.CommandFailed;
    }

    err_handle_w = libc.CreateFileA(
        err_pipe.ptr,
        libc.GENERIC_WRITE,
        0,
        saAttr,
        libc.OPEN_EXISTING,
        libc.FILE_FLAG_WRITE_THROUGH | libc.FILE_FLAG_NO_BUFFERING,
        null
    );
    if (err_handle_w == libc.INVALID_HANDLE_VALUE) {
        return error.CommandFailed;
    }
}

/// Need to connect them so the poller can listen to them
fn connect_pipes() Errors!void {
    if (libc.ConnectNamedPipe(out_handle_r, null) != 0) {
        return error.CommandFailed;
    }
    if (libc.ConnectNamedPipe(err_handle_r, null) != 0) {
        return error.CommandFailed;
    }
}

fn run_command(command: []const u8, cwd: []const u8, env_block: [:0]u8) e.Errors!libc.PROCESS_INFORMATION {
    var saAttr = std.mem.zeroes(libc.SECURITY_ATTRIBUTES);
    saAttr.nLength = @sizeOf(libc.SECURITY_ATTRIBUTES);
    saAttr.bInheritHandle = 1;
    saAttr.lpSecurityDescriptor = null;

    try set_pipes(&saAttr);

    if (libc.SetHandleInformation(out_handle_r, libc.HANDLE_FLAG_INHERIT, 0) == 0) {
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

    const cwd_z = std.fmt.allocPrintZ(util.gpa, "{s}", .{cwd})
        catch |err| return e.verbose_error(err, error.ForkFailed);
    defer util.gpa.free(cwd_z);


    if (libc.CreateProcessA(
        null, proc_string.ptr, null,
        null, 1,
        0,
        env_block.ptr, cwd_z.ptr,
        @as([*c]libc.struct__STARTUPINFOA, @ptrCast(&si.StartupInfo)),
        @as([*c]libc.PROCESS_INFORMATION, @ptrCast(&proc_info))
    ) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.CommandFailed;
    }

    try connect_pipes();

    return proc_info;
}
