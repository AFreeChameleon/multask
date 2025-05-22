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

const TaskLogger = @import("../task/logger.zig");
const taskproc = @import("../task/process.zig");
const Process = taskproc.Process;
const Cpu = taskproc.Cpu;
const ExistingLimits = taskproc.ExistingLimits;

const ChildProcess = std.process.Child;


pub fn run_daemon(task: *Task, flags: ForkFlags) e.Errors!void {
    try util.save_stats(task, &flags);

    // Set this to false for dev purposes
    if (true) {
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

        // Creates grandchild process to orphan it so no zombie processes are made
        if (libc.fork() > 0) {
            libc.exit(0);
        }

        // Child logic is here vvv
        log.is_forked = true;
        try close_std_handles();

        _ = libc.umask(0);
        const sid = libc.setsid();
        if (sid < 0) {
            return error.SetSidFailed;
        }
    }

    task.daemon = try Process.init(task, util.get_pid(), null);
    while (true) {
        var child = try run_command(task.stats.command, flags.interactive);
        errdefer _ = child.kill() catch {
            std.process.exit(1);
        };

        task.process = try Process.init(task, child.id, null);
        if (flags.memory_limit > 0) {
            try task.process.?.limit_memory(flags.memory_limit);
        }
        try monitor_process(&child, task, flags.cpu_limit);
        try taskproc.kill_all(&task.process.?);
        if (!flags.persist) {
            break;
        }
        // Persisting with a timeout of 2 seconds
        std.time.sleep(2_000_000_000);
    }
    Cpu.deinit();
}

fn monitor_process(
    child: *ChildProcess,
    task: *Task,
    cpu_limit: util.CpuLimit,
) e.Errors!void {
    try task.process.?.monitor_stats();
    const mode = std.posix.pipe2(.{ .CLOEXEC = true })
        catch return error.TaskFileFailedWrite;
    defer std.posix.close(mode[0]);
    defer std.posix.close(mode[1]);

    var poller = std.io.poll(util.gpa, enum { stdout, stderr, mode }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
        .mode = std.fs.File { .handle = mode[0] }
    });
    defer poller.deinit();

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

    var cpu_sleeping = false;
    var cpu_times: ?CpuLimitTimes = if (cpu_limit != 0)
        get_cpu_limit_times(cpu_limit)
    else null;

    var timeout: i128 = if (cpu_times != null)
        cpu_times.?.alive
        else
            1_000_000_000; // 1 second in nanoseconds
    var monitor_time = std.time.nanoTimestamp();
    var refresh_processes = false;
    // Ctrl+C and interrupts will trigger this if not in forked
    // And a bug will lead to an extra (), at the end of the processes file
    while (
        // Instead of polling every millisecond, we could do calculations
        // For when the next second will be and set that
        poller.pollTimeout(@intCast(timeout))
            catch |err| return e.verbose_error(err, error.CommandFailed)
    ) {
        const existing_limits: ExistingLimits = ExistingLimits {
            .mem = task.stats.memory_limit,
            .cpu = task.stats.cpu_limit
        };
        const stdout_buffer = util.gpa.alloc(u8, poller.fifo(.stdout).readableLength())
            catch |err| return e.verbose_error(err, error.CommandFailed);
        defer util.gpa.free(stdout_buffer);
        const stderr_buffer = util.gpa.alloc(u8, poller.fifo(.stderr).readableLength())
            catch |err| return e.verbose_error(err, error.CommandFailed);
        defer util.gpa.free(stderr_buffer);
        _ = poller.fifo(.stdout).read(stdout_buffer);
        _ = poller.fifo(.stderr).read(stderr_buffer);

        // If there are no logs, this will be skipped
        if (stdout_buffer.len > 0) {
            try TaskLogger.write_timed_logs(
                &out_new_line,
                stdout_buffer,
                @TypeOf(stdout_writer),
                &stdout_writer
            );
        }
        if (stderr_buffer.len > 0) {
            try TaskLogger.write_timed_logs(
                &err_new_line,
                stderr_buffer,
                @TypeOf(stderr_writer),
                &stderr_writer
            );
        }

        const current_time = std.time.nanoTimestamp();
        var time: i128 = 1_000_000_000;
        if (cpu_times != null) {
            if (cpu_sleeping) {
                time = cpu_times.?.sleep;
            } else {
                time = cpu_times.?.alive;
            }
        }

        timeout = (monitor_time + time) - current_time;
        if (timeout <= 0) {
            refresh_processes = true;
        }

        if (refresh_processes) {
            if (!task.process.?.proc_exists()) {
                const saved_procs = try taskproc.get_running_saved_procs(&task.process.?);
                defer util.gpa.free(saved_procs);
                if (saved_procs.len == 0) {
                    break;
                }
            }
            if (cpu_times == null) {
                try task.process.?.monitor_stats();
                // Refresh process stats
                const stats = try task.files.read_file(Stats);
                if (stats == null) {
                    return error.FailedToGetTaskStats;
                }
                task.stats.deinit();
                task.stats = stats.?;
                if (task.stats.memory_limit != existing_limits.mem) {
                    try task.process.?.limit_memory(task.stats.memory_limit);
                }
                if (task.stats.cpu_limit != existing_limits.cpu) {
                    cpu_times = get_cpu_limit_times(task.stats.cpu_limit);
                }
            } else {
                if (cpu_sleeping) {
                    // Only doing a monitor stats here as it'll be every second
                    // and this code is designed to be run on a 1 second timer
                    try task.process.?.monitor_stats();

                    // Refresh process stats
                    const stats = try task.files.read_file(Stats);
                    if (stats == null) {
                        return error.FailedToGetTaskStats;
                    }
                    task.stats.deinit();
                    task.stats = stats.?;
                    if (task.stats.memory_limit != existing_limits.mem) {
                        try log.printdebug("Refresh lim {d} {d}", .{existing_limits.mem, task.stats.memory_limit});
                        try task.process.?.limit_memory(task.stats.memory_limit);
                    }
                    if (task.stats.cpu_limit != existing_limits.cpu) {
                        try log.printdebug("CPU Refresh lim {d} {d}", .{existing_limits.cpu, task.stats.cpu_limit});
                        cpu_times = get_cpu_limit_times(task.stats.cpu_limit);
                    }

                    try task.process.?.set_all_status(.Active);
                    cpu_sleeping = false;
                    time = cpu_times.?.alive;
                } else {
                    try task.process.?.set_all_status(.Sleep);
                    cpu_sleeping = true;
                    time = cpu_times.?.sleep;
                }
            }
            refresh_processes = false;
            monitor_time = current_time;
            timeout = (monitor_time + time) - current_time;
        }
    }
}

fn run_command(command: []const u8, interactive: bool) e.Errors!ChildProcess {
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
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Pipe;
    child_process.stdin_behavior = .Pipe;
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

