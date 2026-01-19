const std = @import("std");
const libc = @import("../../c.zig").libc;

const t = @import("../../task/index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const e = @import("../../../lib/error.zig");
const Errors = e.Errors;

pub const PipeClient = struct {
    pub const Signals = enum {out, err};
    const Self = @This();

    client_pipe: libc.HANDLE,
    task_id: TaskId,

    /// Connect to the named pipe server in the logs watcher, returns a struct with a write-only pipe if it succeeds and null if it fails
    pub fn connect(task_id: TaskId) Errors!Self {
        var self = Self {
            .task_id = task_id,
            .client_pipe = libc.INVALID_HANDLE_VALUE
        };
        var buf: [128]u8 = undefined;
        const pipe_str = std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-logs", .{task_id})
            catch |err| return e.verbose_error(err, error.CommandFailed);
        self.client_pipe = libc.CreateFileA(pipe_str.ptr, libc.GENERIC_WRITE, 0, null, libc.OPEN_EXISTING, 0, null);

        if (self.client_pipe == libc.INVALID_HANDLE_VALUE) {
            return self;
        }

        // Set pipe to message read mode
        var flags: u32 = libc.PIPE_READMODE_MESSAGE | libc.PIPE_WAIT;
        const success = libc.SetNamedPipeHandleState(self.client_pipe, &flags, null, null);
        if (success == 0) {
            _ = libc.CloseHandle(self.client_pipe);
            self.client_pipe = libc.INVALID_HANDLE_VALUE;
            return self;
        }

        return self;
    }

    /// Signals server pipe stdout/stderr has been written to, 0 for stdout, 1 for stderr
    /// if the client pipe is invalid, it tries to connect again, if that fails, no writing happens
    pub fn signal_server(self: *Self, mode: Signals) Errors!void {
        if (self.client_pipe == libc.INVALID_HANDLE_VALUE) {
            const new_connection = try connect(self.task_id);
            if (new_connection.client_pipe == libc.INVALID_HANDLE_VALUE) {
                return;
            }
            self.client_pipe = new_connection.client_pipe;
        }

        const msg: [2]u8 = switch (mode) {
            .out => [2]u8{1, 0},
            .err => [2]u8{2, 0},
        };
        const res = libc.WriteFile(self.client_pipe, &msg, msg.len, null, null);

        if (res == 0) {
            return error.FailedToSignalLogger;
        }

        const flush_res = libc.FlushFileBuffers(self.client_pipe);

        if (flush_res == 0) {
            return error.FailedToSignalLogger;
        }
    }
};