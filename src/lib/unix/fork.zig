const builtin = @import("builtin");
const std = @import("std");
const libc = @import("../c.zig").libc;
const log = @import("../log.zig");

const e = @import("../error.zig");
const Errors = e.Errors;

const util = @import("../util.zig");
const ForkFlags = util.ForkFlags;

const MainFiles = @import("../file.zig").MainFiles;

const t = @import("../task/index.zig");
const Task = t.Task;
const Files = t.Files;


const Stats = @import("../task/stats.zig").Stats;
const taskenv = @import("../task/env.zig");

const read_command_std_output = @import("./logs.zig").read_command_std_output;
const monitor_processes = @import("./refresh.zig").monitor_processes;

const TaskFiles = @import("../task/file.zig").Files;

const TaskLogger = @import("../task/logger.zig");
const taskproc = @import("../task/process.zig");
const Process = taskproc.Process;
const Cpu = taskproc.Cpu;
const ExistingLimits = taskproc.ExistingLimits;
const Monitoring = taskproc.Monitoring;

const ChildProcess = std.process.Child;


pub fn run_daemon(task: *Task, flags: ForkFlags) e.Errors!void {
    try TaskFiles.save_stats(task, &flags);
    // Set this to false for dev purposes
    if (false) {
        const process_id = libc.fork();

        // Failed fork
        if (process_id < 0) {
            return error.ForkFailed;
        }

        // Parent process - need to kill it
        if (process_id > 0) {
            try log.printinfo("Process id of child process {d}", .{process_id});
            return;
        }

        // Child logic is here vvv
        log.is_forked = true;
        try close_std_handles();

        _ = libc.umask(0);
        const sid = libc.setsid();
        if (sid < 0) {
            return error.SetSidFailed;
        }

        // Creates grandchild process to orphan it so no zombie processes are made
        if (libc.fork() > 0) {
            libc.exit(0);
        }
    }
    defer task.deinit();

    var envs = try taskproc.get_envs(task, flags.update_envs);
    defer envs.deinit();
    if (flags.no_run) {
        return;
    }
    try taskenv.add_multask_taskid_to_map(&envs, task.id);

    task.resources.?.meta = Cpu.init();
    task.daemon = try Process.init(task, util.get_pid(), null);

    while (true) {
        var child = try run_command(task.stats.?.command, task.stats.?.cwd, task.stats.?.interactive, envs);
        errdefer _ = child.kill() catch {
            std.process.exit(1);
        };

        task.process = try Process.init(task, child.id, null);
        if (task.stats.?.memory_limit > 0) {
            try task.process.?.limit_memory(task.stats.?.memory_limit);
        }
        try spawn_worker_threads(&child, task);
        try taskproc.kill_all(&task.process.?);
        if (!task.stats.?.persist) {
            break;
        }
        // Persisting with a timeout of 2 seconds
        std.time.sleep(2_000_000_000);
        const new_stats = try task.files.?.read_file(Stats);
        if (new_stats == null) {
            break;
        }
        task.stats.?.deinit();
        task.stats = new_stats;
    }
}

fn spawn_worker_threads(
    child: *ChildProcess,
    task: *Task,
) e.Errors!void {
    var sleep_condition = std.Thread.Condition{};
    var sleep_mutex = std.Thread.Mutex{};
    const log_thread = std.Thread.spawn(.{ .allocator = util.gpa }, read_command_std_output, .{
        child,
        task,
        &sleep_condition,
    }) catch |err| return e.verbose_error(err, error.FailedToSpawnThread);
    const monitor_thread = std.Thread.spawn(.{ .allocator = util.gpa }, monitor_processes, .{
        task,
        &sleep_condition,
        &sleep_mutex,
    }) catch |err| return e.verbose_error(err, error.FailedToSpawnThread);

    log_thread.join();
    monitor_thread.join();

    try log.printdebug("No more saved processes are alive.", .{});
}

fn run_command(
    command: []const u8,
    cwd: []const u8,
    interactive: bool,
    envs: std.process.EnvMap
) e.Errors!ChildProcess {
    var build_args = std.ArrayList([]const u8).init(util.gpa);
    defer build_args.deinit();
    const shell_path = try util.get_shell_path();
    defer util.gpa.free(shell_path);
    var shell_args: []const u8 = "-c";
    if (interactive) {
        shell_args = "-ic";
    }
    build_args.appendSlice(&[_][]const u8{
        shell_path,
        shell_args,
        command,
    }) catch |err| return e.verbose_error(err, error.CommandFailed);

    var child_process = ChildProcess.init(
        build_args.items,
        util.gpa
    );
    child_process.env_map = &envs;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Pipe;
    child_process.stdin_behavior = .Pipe;
    child_process.cwd = cwd;
    child_process.spawn()
        catch |err| return e.verbose_error(err, error.CommandFailed);
    return child_process;
}

fn close_std_handles() !void {
    const handles  = [_]i32{
        libc.STDIN_FILENO,
        libc.STDOUT_FILENO,
        libc.STDERR_FILENO
    };
    for (handles) |handle| {
        if (libc.fcntl(handle, libc.F_GETFD) != 1 and std.c._errno().* != libc.EBADF) {
            const res = libc.close(handle);
            if (res != 0) {
                return error.StdHandleCloseFailed;
            }
        }
    }
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

