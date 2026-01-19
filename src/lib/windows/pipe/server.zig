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

pub const SignalNamedPipes = struct {
    pub const Signals = enum {out, err};
    const Mode = enum {read_async, write};

    task_id: TaskId,

    out: libc.HANDLE,
    err: libc.HANDLE,


    /// When a change to a file happens, these are what will be signaled for the logs watching
    pub fn init_write(task_id: TaskId) Errors!SignalNamedPipes {
        const out_pipe = try open_or_create_pipe(task_id, .out, .write);
        const err_pipe = try open_or_create_pipe(task_id, .err, .write);

        return .{
            .task_id = task_id,
            .out = out_pipe,
            .err = err_pipe
        };
    }

    /// Opens the signal named pipes with read permissions with overlapped - async
    pub fn init_read(task_id: TaskId) Errors!SignalNamedPipes {
        const out = try open_or_create_pipe(task_id, .out, .read_async);
        const err = try open_or_create_pipe(task_id, .err, .read_async);

        return .{
            .task_id = task_id,
            .out = out.?,
            .err = err.?,
        };
    }

    /// Closes handles from the opened pipes, the handles to the named pipes aren't closed
    pub fn deinit(self: *const SignalNamedPipes) void {
        _ = libc.CloseHandle(self.out);
        _ = libc.CloseHandle(self.err);
    }

    /// Signals the named pipe it has been written to
    pub fn signal(task_id: TaskId, sig: Signals) Errors!void {
        const pipe = try open_pipe(task_id, sig, .write);

        if (pipe == null) {
            return;
        }

        const res = libc.WriteFile(
            pipe,
            null,
            0,
            0,
            null
        );

        if (res == 0) {
            return error.FailedToWatchFile;
        }

        _ = libc.CloseHandle(pipe);
    }

    fn open_or_create_pipe(task_id: TaskId, sig: Signals, mode: Mode) Errors!libc.HANDLE {
        var pipe = try open_pipe(task_id, sig, mode);
        if (pipe == null) {
            pipe = try create_pipe(task_id, sig);
        }
        return pipe;
    }

    fn create_pipe(task_id: TaskId, sig: Signals) Errors!libc.HANDLE {
        var buf: [128]u8 = undefined;
        const pipe_str = switch (sig) {
            .out => |_| inner: {
                break :inner std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-stdout", .{task_id})
                    catch |err| return e.verbose_error(err, error.CommandFailed);
            },
            .err => |_| inner: {
                break :inner std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-stderr", .{task_id})
                    catch |err| return e.verbose_error(err, error.CommandFailed);
            }
        };
        const pipe = libc.CreateNamedPipeA(
            pipe_str.ptr,
            libc.PIPE_ACCESS_DUPLEX | libc.FILE_FLAG_FIRST_PIPE_INSTANCE,
            libc.PIPE_TYPE_MESSAGE | libc.PIPE_WAIT,
            1,
            0,
            0,
            0,
            null
        );

        if (pipe == libc.INVALID_HANDLE_VALUE) {
            return error.FailedToWatchFile;
        }

        return pipe;
    }

    pub fn create_main_pipe(task_id: TaskId) Errors!libc.HANDLE {
        var buf: [128]u8 = undefined;
        const pipe_str = std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-logs", .{task_id})
            catch |err| return e.verbose_error(err, error.CommandFailed);
        const pipe = libc.CreateNamedPipeA(
            pipe_str.ptr,
            libc.PIPE_ACCESS_DUPLEX | libc.FILE_FLAG_FIRST_PIPE_INSTANCE | libc.FILE_FLAG_OVERLAPPED,
            libc.PIPE_TYPE_MESSAGE | libc.PIPE_WAIT,
            1,
            1,
            1,
            0,
            null
        );

        if (pipe == libc.INVALID_HANDLE_VALUE) {
            if (std.os.windows.GetLastError() == .PIPE_BUSY) {
                return error.WindowsLogWatcherAlreadyRunning;
            }
            return error.FailedToWatchFile;
        }

        return pipe;
    }

    /// Connect to the named pipe server in the logs watcher, returns a write-only pipe if it succeeds and null if it fails
    pub fn connect_to_main_pipe_write(task_id: TaskId) Errors!?libc.HANDLE {
        var buf: [128]u8 = undefined;
        const pipe_str = std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-logs", .{task_id})
            catch |err| return e.verbose_error(err, error.CommandFailed);
        const pipe = libc.CreateFileA(pipe_str.ptr, libc.GENERIC_WRITE, 0, null, libc.OPEN_EXISTING, 0, null);

        if (pipe == libc.INVALID_HANDLE_VALUE) {
            return null;
        }

        // Set pipe to message read mode
        const success = libc.SetNamedPipeHandleState(pipe, libc.PIPE_READMODE_MESSAGE, null, null);
        if (success == 0) {
            _ = libc.CloseHandle(pipe);
            return null;
        }

        return pipe;
    }

    pub fn send_signal_to_main_pipe(pipe: libc.HANDLE, mode: Signals) Errors!void {
        const msg: [1]u8 = switch (mode) {
            .out => [1]u8{0},
            .err => [1]u8{1},
        };
        const success = libc.WriteFile(pipe, &msg, msg.len, null, null);

        if (success == 0) {
            return error.FailedToSignalLogger;
        }
    }

    /// Opens named pipe, if it doesn't exist, null is returned
    pub fn open_pipe(task_id: TaskId, sig: Signals, mode: Mode) Errors!libc.HANDLE {
        var buf: [128]u8 = undefined;
        const pipe_str = switch (sig) {
            .out => |_| inner: {
                break :inner std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-stdout", .{task_id})
                    catch |err| return e.verbose_error(err, error.CommandFailed);
            },
            .err => |_| inner: {
                break :inner std.fmt.bufPrintZ(&buf, "\\\\.\\pipe\\multask-task-{d}-stderr", .{task_id})
                    catch |err| return e.verbose_error(err, error.CommandFailed);
            }
        };
        
        const pipe = switch (mode) {
            .read_async => libc.CreateFileA(
                pipe_str.ptr,
                libc.GENERIC_READ,
                libc.FILE_SHARE_READ,
                null,
                libc.OPEN_EXISTING,
                libc.FILE_FLAG_OVERLAPPED,
                null
            ),
            .write => libc.CreateFileA(
                pipe_str.ptr,
                libc.GENERIC_WRITE,
                0,
                null,
                libc.OPEN_EXISTING,
                libc.FILE_ATTRIBUTE_NORMAL,
                null
            )
        };


        if (pipe == libc.INVALID_HANDLE_VALUE) {
            if (std.os.windows.GetLastError() == std.os.windows.Win32Error.FILE_NOT_FOUND) {
                return null;
            }
            return error.FailedToWatchFile;
        }

        return pipe;
    }

    /// Waits from a response from the pipe server or stdin
    pub fn read_from_client_or_stdin(pipe: libc.HANDLE, pipe_overlapped: *libc.OVERLAPPED) Errors!enum { out, err, stdin, ended_connection } {
        const stdin = libc.GetStdHandle(libc.STD_INPUT_HANDLE);
        var buf: [2]u8 = undefined;
        const read_res = libc.ReadFile(pipe, &buf, 2, null, pipe_overlapped);
        if (read_res == 0 and std.os.windows.GetLastError() != .IO_PENDING) {
            return error.FailedToWatchFile;
        }
        const handles = [_]libc.HANDLE{pipe_overlapped.hEvent.?, stdin};
        const res = libc.WaitForMultipleObjects(handles.len, &handles, 0, libc.INFINITE);
        if (res == libc.WAIT_OBJECT_0 + 1) {
            return .stdin;
        }

        if (res != libc.WAIT_OBJECT_0) {
            return error.FailedToWatchFile;
        }

        var written: c_ulong = 0;
        const overlapped_res = libc.GetOverlappedResult(pipe, pipe_overlapped, &written, 1);
        if (overlapped_res == 0) {
            const code = std.os.windows.GetLastError();
            if (code == .BROKEN_PIPE) {
                const disconnect_res = libc.DisconnectNamedPipe(pipe);
                if (disconnect_res == 0) {
                    return error.FailedToWatchFile;
                }
                return .ended_connection;
            }
            return error.FailedToWatchFile;
        }

        return switch (buf[0]) {
            1 => .out,
            2 => .err,
            else => error.FailedToWatchFile
        };
    }
};