const std = @import("std");

const t = @import("../task/index.zig");
const Task = t.Task;
const TaskLogger = @import("../task/logger.zig");
const e = @import("../error.zig");
const Errors = e.Errors;
const util = @import("../util.zig");
const log = @import("../log.zig");

const taskproc = @import("../task/process.zig");

const ChildProcess = std.process.Child;
const FD_CLOEXEC: c_int = std.c.FD_CLOEXEC;

pub fn read_command_std_output(
    child: *ChildProcess,
    task: *Task,
    sleep_condition: *std.Thread.Condition,
) Errors!void {
    errdefer {
        if (task.daemon == null) {
            @panic("Failed to kill process");
        }
        taskproc.kill_all(&task.daemon.?) catch @panic("Failed to kill process");
    }
    try inner_read_command_std_output(child, task, sleep_condition);
}

fn inner_read_command_std_output(
    child: *ChildProcess,
    task: *Task,
    sleep_condition: *std.Thread.Condition,
) Errors!void {
    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    var poller = std.io.poll(util.gpa, enum { stdout, stderr }, .{
        .stdout = stdout,
        .stderr = stderr,
    });
    defer poller.deinit();

    // Seeking to end to truncate logs
    const outfile = try task.files.?.get_file("stdout");
    defer outfile.close();
    const errfile = try task.files.?.get_file("stderr");
    defer errfile.close();
    outfile.seekFromEnd(0)
        catch |err| return e.verbose_error(err, error.CommandFailed);
    errfile.seekFromEnd(0)
        catch |err| return e.verbose_error(err, error.CommandFailed);
    var stdout_writer = std.io.bufferedWriter(outfile.writer());
    var stderr_writer = std.io.bufferedWriter(errfile.writer());

    var out_buffer: [TaskLogger.LOG_BUF_SIZE]u8 = std.mem.zeroes([TaskLogger.LOG_BUF_SIZE]u8);
    var err_buffer: [TaskLogger.LOG_BUF_SIZE]u8 = std.mem.zeroes([TaskLogger.LOG_BUF_SIZE]u8);
    var out_newline = true;
    var err_newline = true;

    while (
        poller.poll()
            catch |err| return e.verbose_error(err, error.CommandFailed)
    ) {
        const out_written = poller.fifo(.stdout).read(&out_buffer);
        defer out_buffer = std.mem.zeroes([TaskLogger.LOG_BUF_SIZE]u8);
        const err_written = poller.fifo(.stderr).read(&err_buffer);
        defer err_buffer = std.mem.zeroes([TaskLogger.LOG_BUF_SIZE]u8);

        if (out_written == 0 and err_written == 0) {
            return;
        }

        // If there are no logs, this will be skipped
        if (out_written > 0) {
            outfile.lock(.exclusive)
                catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
            defer outfile.unlock();
            out_newline = try TaskLogger.write_timed_logs(
                out_newline,
                out_buffer[0..out_written],
                @TypeOf(stdout_writer),
                &stdout_writer
            );
        }
        if (err_written > 0) {
            errfile.lock(.exclusive)
                catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
            defer errfile.unlock();
            err_newline = try TaskLogger.write_timed_logs(
                err_newline,
                err_buffer[0..err_written],
                @TypeOf(stderr_writer),
                &stderr_writer
            );
        }
    }
    sleep_condition.signal();
}
