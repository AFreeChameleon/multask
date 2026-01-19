const std = @import("std");
const ChildProcess = std.process.Child;

const libc = @import("../../c.zig").libc;
const e = @import("../../../lib/error.zig");
const Errors = e.Errors;

const t = @import("../../task/index.zig");
const Task = t.Task;
const TaskId = t.TaskId;
const TaskLogger = @import("../../task/logger.zig");
const util = @import("../../util.zig");
const log = @import("../../log.zig");
const taskproc = @import("../../task/process.zig");
const PathBuilder = @import("../../file.zig").PathBuilder;

const PipeClient = @import("../pipe/client.zig").PipeClient;

fn write_output_to_file(
    comptime T: type,
    writer: anytype,
    handle: libc.HANDLE,
    new_line: bool,
) Errors!bool {
    var queued_bytes: libc.DWORD = 0;

    if (libc.PeekNamedPipe(handle, null, 0, 0, &queued_bytes, 0) == 0) {
        return error.CommandFailed;
    }
    if (queued_bytes > 0) {
        var dw_read: libc.DWORD = 0;
        const buf = util.gpa.alloc(u8, queued_bytes)
            catch |err| return e.verbose_error(err, error.CommandFailed);
        defer util.gpa.free(buf);
        if (libc.ReadFile(handle, buf.ptr, queued_bytes, &dw_read, null) == 0) {
            return error.CommandFailed;
        }
        return try TaskLogger.write_timed_logs(
            new_line,
            buf,
            T,
            writer
        );
    }
    return true;
}

fn poll(stdout: libc.HANDLE, stderr: libc.HANDLE, proc_event_handle: libc.HANDLE) Errors!?c_ulong {
    var out_overlapped: libc.OVERLAPPED = std.mem.zeroes(libc.OVERLAPPED);
    out_overlapped.hEvent = libc.CreateEventA(null, 0, 0, null);
    var err_overlapped: libc.OVERLAPPED = std.mem.zeroes(libc.OVERLAPPED);
    err_overlapped.hEvent = libc.CreateEventA(null, 0, 0, null);

    var out_buf: [0]u8 = undefined;
    var out_bytes_read: u32 = 0;
    const out_read = libc.ReadFile(stdout, &out_buf, 0, &out_bytes_read, &out_overlapped);
    if (out_read == 0 and libc.GetLastError() != libc.ERROR_IO_PENDING) {
        return error.FailedToWatchFile;
    }

    var err_buf: [0]u8 = undefined;
    var err_bytes_read: u32 = 0;
    const err_read = libc.ReadFile(stderr, &err_buf, 0, &err_bytes_read, &err_overlapped);
    if (err_read == 0 and libc.GetLastError() != libc.ERROR_IO_PENDING) {
        return error.FailedToWatchFile;
    }

    const handles: [3]libc.HANDLE = .{out_overlapped.hEvent, err_overlapped.hEvent, proc_event_handle};


    const res = libc.WaitForMultipleObjects(handles.len, &handles, 0, std.os.windows.INFINITE);

    return switch (res) {
        libc.WAIT_ABANDONED_0, libc.WAIT_ABANDONED_0 + 1,
        libc.WAIT_TIMEOUT, libc.WAIT_FAILED => null,
        else => res
    };
}

pub fn read_command_std_output(
    stdout: libc.HANDLE,
    stderr: libc.HANDLE,
    task: *Task,
    proc_event_handle: libc.HANDLE
) Errors!void {
    errdefer {
        if (task.daemon == null) {
            @panic("Failed to kill process");
        }
        taskproc.kill_all(&task.daemon.?) catch @panic("Failed to kill process");
    }
    try inner_read_command_std_output(stdout, stderr, task, proc_event_handle);
}

fn inner_read_command_std_output(
    stdout: libc.HANDLE,
    stderr: libc.HANDLE,
    task: *Task,
    proc_event_handle: libc.HANDLE
) Errors!void {
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
    
    // Seeking to end to truncate logs
    var out_newline = true;
    var err_newline = true;

    var logs_client = try PipeClient.connect(task.id);

    while (
        try poll(stdout, stderr, proc_event_handle)
    ) |event| {
        switch (event) {
            // Stdout
            libc.WAIT_OBJECT_0 => {
                out_newline = try write_output_to_file(
                    @TypeOf(stdout_writer), &stdout_writer, stdout, out_newline
                );
                try logs_client.signal_server(.out);
            },
            // Stderr
            libc.WAIT_OBJECT_0 + 1 => {
                err_newline = try write_output_to_file(
                    @TypeOf(stderr_writer), &stderr_writer, stderr, err_newline
                );
                try logs_client.signal_server(.err);
            },
            libc.WAIT_OBJECT_0 + 2 => break,
            else => return error.TaskFileFailedWrite
        }
    }
}

