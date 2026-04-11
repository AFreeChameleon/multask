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

    var out_fbs = std.io.fixedBufferStream(&out_buffer);
    var out_bufw = std.io.bufferedWriter(out_fbs.writer());
    const out_bufw_writer = &out_bufw.writer();

    var err_fbs = std.io.fixedBufferStream(&err_buffer);
    var err_bufw = std.io.bufferedWriter(err_fbs.writer());
    const err_bufw_writer = &err_bufw.writer();

    while (
        poller.poll()
            catch |err| return e.verbose_error(err, error.CommandFailed)
    ) {
        var total_out_bytes_read: usize = 0;
        var total_err_bytes_read: usize = 0;

        while (true) {
            const out_bytes_read = poller.fifo(.stdout).read(&out_buffer);
            const err_bytes_read = poller.fifo(.stderr).read(&err_buffer);

            if (out_bytes_read == 0 and err_bytes_read == 0) {
                break;
            }
            total_out_bytes_read += out_bytes_read;
            total_err_bytes_read += err_bytes_read;

            if (err_bytes_read > 0) {
                _ = err_bufw_writer.write(err_buffer[0..err_bytes_read])
                    catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
            }
            if (out_bytes_read > 0) {
                _ = out_bufw_writer.write(out_buffer[0..out_bytes_read])
                    catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
            }
            
            // Need to run poll again because poll only loads 512 chars into the buffer which makes it hard to
            // judge new lines from the ends of previous lines
            const res = poller.pollTimeout(1)
                catch |err| return e.verbose_error(err, error.CommandFailed);
            const out_write_len = poller.fifo(.stdout).writableLength();
            const err_write_len = poller.fifo(.stderr).writableLength();
            if (
                !res or
                total_out_bytes_read + out_write_len >= out_buffer.len or
                total_err_bytes_read + err_write_len >= err_buffer.len
            ) {
                break;
            }
        }

        if (out_bufw.end > 0) {
            out_bufw.flush()
                catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
            const content = out_fbs.getWritten();
            try TaskLogger.write_timed_logs(
                content,
                @TypeOf(stdout_writer),
                &stdout_writer
            );
            out_fbs.reset();
        }
        if (err_bufw.end > 0) {
            err_bufw.flush()
                catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
            const content = err_fbs.getWritten();
            try TaskLogger.write_timed_logs(
                content,
                @TypeOf(stderr_writer),
                &stderr_writer
            );
            err_fbs.reset();
        }
    }
    sleep_condition.signal();
}
