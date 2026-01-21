const std = @import("std");
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const libc = @import("../c.zig").libc;
const HANDLE = libc.HANDLE;
const util = @import("../util.zig");
const log = @import("../log.zig");
const Pid = util.Pid;
const e = @import("../error.zig");
const Errors = e.Errors;
const WindowsProcess = @import("./process.zig").WindowsProcess;

const t = @import("../task/index.zig");
const TaskId = t.TaskId;

const tf = @import("../task/file.zig");

const PathBuilder = @import("../file.zig").PathBuilder;

const SignalNamedPipes = @import("./pipe/server.zig").SignalNamedPipes;

pub const TaskReadProcess = struct {
    pid: Pid,
    starttime: u64,

    pub fn init(proc: *const WindowsProcess) TaskReadProcess {
        return TaskReadProcess {
            .pid = proc.pid,
            .starttime = proc.starttime
        };
    }
};
pub const ReadProcess = struct {
    task: TaskReadProcess,
    pid: Pid,
    starttime: u64,
    children: ?[]ReadProcess,

    pub fn init(proc: *const WindowsProcess, task_proc: TaskReadProcess, children: ?[]ReadProcess) ReadProcess {
        return ReadProcess {
            .pid = proc.pid,
            .starttime = proc.starttime,
            .task = task_proc,
            .children = children
        };
    }

    pub fn deinit(self: *ReadProcess) void {
        if (self.children != null) {
            util.gpa.free(self.children.?);
        }
    }

    pub fn clone(self: *const ReadProcess) Errors!ReadProcess {
        const task_proc = TaskReadProcess {
            .pid = self.task.pid,
            .starttime = self.task.starttime,
        };
        const proc = ReadProcess {
            .task = task_proc,
            .pid = self.pid,
            .starttime = self.starttime,
            .children = util.gpa.dupe(ReadProcess, self.children.?)
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses)
        };
        return proc;
    }
};

pub const LogFileListener = struct {
    pub const ChangeEvents = enum {stdin_changed, file_changed};
    var original_terminal_mode: u32 = 0;

    /// This is here for testing.
    /// These functions contain libc things and that's not realistic to test.
    pub const IO = struct {
        get_stdin_handle: fn () Errors!HANDLE,
        create_overlapped_event: fn () Errors!HANDLE,
        set_raw_terminal: fn (stdin: HANDLE) Errors!void,
        restore_terminal: fn (sig: u32) callconv(.c) std.os.windows.BOOL,
        get_folder_handle: fn (path: []u8) Errors!HANDLE,
        close_handle: fn (handle: HANDLE) void,
        poll: fn (self: *LogFileListener) Errors!?tf.StdLogFileEvent,
    };
    pub const MainIO: IO = .{
        .get_stdin_handle = LogFileListener.get_stdin_handle,
        .create_overlapped_event = LogFileListener.create_overlapped_event,
        .set_raw_terminal = LogFileListener.set_raw_terminal,
        .restore_terminal = LogFileListener.restore_terminal,
        .get_folder_handle = LogFileListener.get_folder_handle,
        .close_handle = LogFileListener.close_handle,
        .poll = LogFileListener.poll,
    };

    task_folder_handle: HANDLE,
    stdin_handle: HANDLE,
    event_buf: [1024]u8 align(@alignOf(libc.FILE_NOTIFY_INFORMATION)),
    folder_path_buf: [std.fs.max_path_bytes]u8,

    pipe_overlapped: libc.OVERLAPPED,
    pipe_signal_overlapped: libc.OVERLAPPED,
    pipe_server: libc.HANDLE,
    task_id: TaskId,

    pub fn setup(task_id: TaskId, io: IO) Errors!LogFileListener {
        var data = LogFileListener{
            .stdin_handle = try io.get_stdin_handle(),
            .task_folder_handle = null,
            .event_buf = std.mem.zeroes([1024]u8),
            .folder_path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8),

            .pipe_overlapped = std.mem.zeroes(libc.OVERLAPPED),
            .pipe_signal_overlapped = std.mem.zeroes(libc.OVERLAPPED),
            .task_id = task_id,
            .pipe_server = try SignalNamedPipes.create_main_pipe(task_id)
        };
        data.pipe_overlapped.hEvent = try io.create_overlapped_event();
        data.pipe_signal_overlapped.hEvent = try io.create_overlapped_event();

        try io.set_raw_terminal(data.stdin_handle);
        errdefer _ = io.restore_terminal(0);

        var fbs = std.io.fixedBufferStream(&data.folder_path_buf);
        var bw = std.io.bufferedWriter(fbs.writer());
        const bw_writer = &bw.writer();

        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        try PathBuilder.add_tasks_dir(bw_writer);
        try PathBuilder.add_task_dir(bw_writer, task_id);
        try PathBuilder.add_terminator(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.FailedToWatchFile);
        data.task_folder_handle = try io.get_folder_handle(fbs.getWritten());

        if (
            data.pipe_overlapped.hEvent == null or data.pipe_overlapped.hEvent.? == libc.INVALID_HANDLE_VALUE or
            data.pipe_signal_overlapped.hEvent == null or data.pipe_signal_overlapped.hEvent.? == libc.INVALID_HANDLE_VALUE
        ) {
            return error.FailedToWatchFile;
        }

        return data;
    }

    pub fn read(self: *LogFileListener, io: IO) Errors!?tf.StdLogFileEvent {
        if (try self.connect_to_client() == false) {
            return null;
        }
        return try io.poll(self);
    }

    fn close_handle(handle: HANDLE) void {
        _ = libc.CloseHandle(handle);
    }

    pub fn close(self: *const LogFileListener, io: IO) Errors!void {
        io.close_handle(self.task_folder_handle);
        _ = io.restore_terminal(0);
    }

    fn create_overlapped_event() Errors!HANDLE {
        return libc.CreateEventA(null, 0, 0, null);
    }

    fn get_folder_handle(path: []u8) Errors!HANDLE {
        const handle = libc.CreateFileA(
            path.ptr,
            libc.FILE_LIST_DIRECTORY,
            libc.FILE_SHARE_READ | libc.FILE_SHARE_WRITE | libc.FILE_SHARE_DELETE,
            null,
            libc.OPEN_EXISTING,
            libc.FILE_FLAG_BACKUP_SEMANTICS | libc.FILE_FLAG_OVERLAPPED,
            null
        );
        if (handle == null or handle == libc.INVALID_HANDLE_VALUE) {
            return error.FailedToWatchFile;
        }
        return handle.?;
    }

    /// This function is blocking, returns false if the program wants to exit and true if a client connects
    fn connect_to_client(self: *LogFileListener) Errors!bool {
        const res = libc.ConnectNamedPipe(self.pipe_server, &self.pipe_overlapped);

        if (res == 0) {
            const code = std.os.windows.GetLastError();
            // If pipe is already connected to a client
            if (code == .PIPE_BUSY or code == .PIPE_CONNECTED) {
                return true;
            }

            if (code != .IO_PENDING) {
                return error.FailedToWatchFile;
            }
        }

        const handles = [_]HANDLE{
            self.pipe_overlapped.hEvent.?,
            self.stdin_handle
        };

        while (true) {
            const wait_res = libc.WaitForMultipleObjects(handles.len, &handles, 0, libc.INFINITE);
            // if stdin
            if (wait_res == libc.WAIT_OBJECT_0 + 1) {
                if (try read_stdin_byte()) |byte| {
                    if (byte == 'q') {
                        return false;
                    }
                }
            }

            if (wait_res == libc.WAIT_OBJECT_0) {
                break;
            }
        }
        return true;
    }
    
    fn poll(
        self: *LogFileListener
    ) Errors!?tf.StdLogFileEvent {
        const res = try SignalNamedPipes.read_from_client_or_stdin(
            self.pipe_server,
            &self.pipe_signal_overlapped
        );

        if (res == .stdin) {
            if (try read_stdin_byte()) |byte| {
                if (byte == 'q') {
                    return null;
                }
            }
        }

        return switch (res) {
            .out => .out,
            .err => .err,
            .stdin => .skip,
            .ended_connection => .skip
        };
    }

    fn get_stdin_handle() Errors!HANDLE {
        return libc.GetStdHandle(libc.STD_INPUT_HANDLE);
    }

    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_ECHO_INPUT: u32 = 0x0004;
    fn set_raw_terminal(stdin: HANDLE) Errors!void {
        if (stdin == null) {
            return error.FailedToWatchFile;
        }

        const get_res = std.os.windows.kernel32.GetConsoleMode(stdin.?, &LogFileListener.original_terminal_mode);
        if (get_res == 0) {
            return error.FailedToWatchFile;
        }

        const new_mode = LogFileListener.original_terminal_mode
            & ~ENABLE_LINE_INPUT
            & ~ENABLE_ECHO_INPUT;

        const set_res = std.os.windows.kernel32.SetConsoleMode(stdin.?, new_mode);
        if (set_res == 0) {
            return error.FailedToWatchFile;
        }

        const ctrl_res = std.os.windows.kernel32.SetConsoleCtrlHandler(restore_terminal, 1);
        if (ctrl_res == 0) {
            _ = restore_terminal(0);
            return error.FailedToWatchFile;
        }
    }

    fn restore_terminal(_: u32) callconv(.c) std.os.windows.BOOL {
        const stdin = get_stdin_handle() catch {
            @panic("Failed to restore terminal to default setting, please restart the terminal.");
        };
        if (stdin == null) {
            @panic("Failed to restore terminal to default setting, please restart the terminal.");
        }
        const res = std.os.windows.kernel32.SetConsoleMode(stdin.?, LogFileListener.original_terminal_mode);
        if (res == 0) {
            @panic("Failed to restore terminal to default setting, please restart the terminal.");
        }
        return 0;
    }

    fn read_stdin_byte() Errors!?u8 {
        var record: libc.INPUT_RECORD = undefined;
        var events_read: u32 = 0;
        const stdin = try get_stdin_handle();
        _ = libc.ReadConsoleInputW(stdin, &record, 1, &events_read);
        if (events_read > 0 and record.EventType == libc.KEY_EVENT) {
            return record.Event.KeyEvent.uChar.AsciiChar;
        }
        return null;
    }
};

test "lib/windows/file.zig" {
    std.debug.print("\n--- lib/windows/file.zig ---\n", .{});
}

test "LogFileListener create_overlapped_event called" {
    std.debug.print("LogFileListener create_overlapped_event called\n", .{});
    const test_io = LogFileListener.IO{
        .create_overlapped_event = struct {
            fn exec() Errors!HANDLE {
                return error.TestFunctionCalled; 
            }
        }.exec,
        .get_stdin_handle = struct {
            fn exec() Errors!HANDLE {
                return null;
            }
        }.exec,
        .set_raw_terminal = struct {
            fn exec(_: HANDLE) Errors!void {
                @panic("Should not be reached");
            }
        }.exec,
        .restore_terminal = struct {
            fn exec(_: u32) c_int {
                @panic("Should not be reached");
            }
        }.exec,
        .poll = struct {
            fn exec(_: *LogFileListener) Errors!LogFileListener.ChangeEvents {
                @panic("Should not be reached");
            }
        }.exec,
        .get_folder_handle = struct {
            fn exec(_: []u8) Errors!HANDLE {
                @panic("Should not be reached");
            }
        }.exec,
        .get_file_event = struct {
            fn exec(_: *LogFileListener, _: []u8) Errors!u32 {
                @panic("Should not be reached");
            }
        }.exec,
        .close_handle = struct {
            fn exec(_: HANDLE) void {
                @panic("Should not be reached");
            }
        }.exec,
    };

    try expectError(error.TestFunctionCalled, LogFileListener.setup(1, test_io));
}

test "LogFileListener get_stdin_handle called" {
    std.debug.print("LogFileListener get_stdin_handle called\n", .{});
    const test_io = LogFileListener.IO{
        .create_overlapped_event = struct {
            fn exec() Errors!HANDLE {
                return null;
            }
        }.exec,
        .get_stdin_handle = struct {
            fn exec() Errors!HANDLE {
                return error.TestFunctionCalled;
            }
        }.exec,
        .set_raw_terminal = struct {
            fn exec(_: HANDLE) Errors!void {
                @panic("Should not be reached");
            }
        }.exec,
        .restore_terminal = struct {
            fn exec(_: u32) c_int {
                @panic("Should not be reached");
            }
        }.exec,
        .get_folder_handle = struct {
            fn exec(_: []u8) Errors!HANDLE {
                @panic("Should not be reached");
            }
        }.exec,
        .poll = struct {
            fn exec(_: *LogFileListener) Errors!LogFileListener.ChangeEvents {
                @panic("Should not be reached");
            }
        }.exec,
        .get_file_event = struct {
            fn exec(_: *LogFileListener, _: []u8) Errors!u32 {
                @panic("Should not be reached");
            }
        }.exec,
        .close_handle = struct {
            fn exec(_: HANDLE) void {
                @panic("Should not be reached");
            }
        }.exec,
    };

    try expectError(error.TestFunctionCalled, LogFileListener.setup(1, test_io));
}

test "LogFileListener no event written skip" {
    std.debug.print("LogFileListener no event written skip\n", .{});
    const test_io = LogFileListener.IO{
        .create_overlapped_event = struct {
            fn exec() Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .get_stdin_handle = struct {
            fn exec() Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .set_raw_terminal = struct {
            fn exec(_: HANDLE) Errors!void {}
        }.exec,
        .restore_terminal = struct {
            fn exec(_: u32) c_int { return 0; }
        }.exec,
        .get_folder_handle = struct {
            fn exec(_: []u8) Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .poll = struct {
            fn exec(_: *LogFileListener) Errors!LogFileListener.ChangeEvents {
                return .file_changed;
            }
        }.exec,
        .get_file_event = struct {
            fn exec(_: *LogFileListener, _: []u8) Errors!u32 {
                return 0;
            }
        }.exec,
        .close_handle = struct {
            fn exec(_: HANDLE) void {}
        }.exec,
    };

    var lis = try LogFileListener.setup(1, test_io);
    const res = try lis.read(test_io);
    try expect(res == .skip);
}

test "LogFileListener out event written" {
    std.debug.print("LogFileListener out event written\n", .{});
    const test_io = LogFileListener.IO{
        .create_overlapped_event = struct {
            fn exec() Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .get_stdin_handle = struct {
            fn exec() Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .set_raw_terminal = struct {
            fn exec(_: HANDLE) Errors!void {}
        }.exec,
        .restore_terminal = struct {
            fn exec(_: u32) c_int { return 0; }
        }.exec,
        .get_folder_handle = struct {
            fn exec(_: []u8) Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .poll = struct {
            fn exec(_: *LogFileListener) Errors!LogFileListener.ChangeEvents {
                return .file_changed;
            }
        }.exec,
        .get_file_event = struct {
            fn exec(_: *LogFileListener, buf: []u8) Errors!u32 {
                const utf8_path = "stdout";
                @memcpy(buf[0..utf8_path.len], "stdout");
                // libc.FILE_ACTION_MODIFIED;
                return 0x00000003;
            }
        }.exec,
        .close_handle = struct {
            fn exec(_: HANDLE) void {}
        }.exec,
    };

    var lis = try LogFileListener.setup(1, test_io);
    const res = try lis.read(test_io);
    try expect(res == .out);
}

test "LogFileListener err event written" {
    std.debug.print("LogFileListener out event written\n", .{});
    const test_io = LogFileListener.IO{
        .create_overlapped_event = struct {
            fn exec() Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .get_stdin_handle = struct {
            fn exec() Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .set_raw_terminal = struct {
            fn exec(_: HANDLE) Errors!void {}
        }.exec,
        .restore_terminal = struct {
            fn exec(_: u32) c_int { return 0; }
        }.exec,
        .get_folder_handle = struct {
            fn exec(_: []u8) Errors!HANDLE {
                var val: u8 = 1;
                return @ptrCast(&val);
            }
        }.exec,
        .poll = struct {
            fn exec(_: *LogFileListener) Errors!LogFileListener.ChangeEvents {
                return .file_changed;
            }
        }.exec,
        .get_file_event = struct {
            fn exec(_: *LogFileListener, buf: []u8) Errors!u32 {
                const utf8_path = "stderr";
                @memcpy(buf[0..utf8_path.len], "stderr");
                // libc.FILE_ACTION_MODIFIED;
                return 0x00000003;
            }
        }.exec,
        .close_handle = struct {
            fn exec(_: HANDLE) void {}
        }.exec,
    };

    var lis = try LogFileListener.setup(1, test_io);
    const res = try lis.read(test_io);
    try expect(res == .err);
}
