const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const e = @import("../error.zig");
const Errors = e.Errors;
const MacosProcess = @import("./process.zig").MacosProcess;

const t = @import("../task/index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const tf = @import("../task/file.zig");

const PathBuilder = @import("../file.zig").PathBuilder;

pub const TaskReadProcess = struct {
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
    
    pub fn init(proc: *const MacosProcess) TaskReadProcess {
        return TaskReadProcess {
            .pid = proc.pid,
            .sid = proc.sid,
            .pgrp = proc.pgrp,
            .starttime = proc.starttime,
        };
    }
};
pub const ReadProcess = struct {
    task: TaskReadProcess,
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
    children: ?[]ReadProcess,

    pub fn init(proc: *const MacosProcess, task_proc: TaskReadProcess, children: ?[]ReadProcess) ReadProcess {
        return ReadProcess {
            .pid = proc.pid,
            .sid = proc.sid,
            .pgrp = proc.pgrp,
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
            .sid = self.task.sid,
            .pgrp = self.task.pgrp,
            .starttime = self.task.starttime,
        };
        const proc = ReadProcess {
            .task = task_proc,
            .pid = self.pid,
            .sid = self.sid,
            .pgrp = self.pgrp,
            .starttime = self.starttime,
            .children = util.gpa.dupe(ReadProcess, self.children.?)
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses)
        };
        return proc;
    }
};

const NUM_EVENTS_TO_MONITOR = 3;
const NUM_EVENTS = 1;
pub const LogFileListener = struct {
    var original_termios: std.c.termios = std.mem.zeroes(std.c.termios);
    /// This is here for testing.
    /// These functions contain libc things and that's not realistic to test.
    pub const IO = struct {
        save_termios: fn () Errors!void,
        set_raw_terminal: fn () Errors!void,
        init_watcher: fn () Errors!i32,
        add_file_watcher: fn (event: *std.c.Kevent, buffer: []u8) Errors!void,
        poll_watcher: fn (self: *LogFileListener) Errors!void,
        read_stdin_byte: fn () Errors!u8,
        deinit_watcher: fn (self: *LogFileListener) void,
    };
    pub const MainIO: IO = .{
        .save_termios = LogFileListener.save_termios,
        .set_raw_terminal = LogFileListener.set_raw_terminal,
        .init_watcher = LogFileListener.init_watcher,
        .add_file_watcher = LogFileListener.add_file_watcher,
        .poll_watcher = LogFileListener.poll_watcher,
        .read_stdin_byte = LogFileListener.read_stdin_byte,
        .deinit_watcher = LogFileListener.deinit_watcher,
    };

    events_to_monitor: [NUM_EVENTS_TO_MONITOR]std.c.Kevent = std.mem.zeroes([NUM_EVENTS_TO_MONITOR]std.c.Kevent),
    event_data: [NUM_EVENTS]std.c.Kevent = std.mem.zeroes([NUM_EVENTS]std.c.Kevent),
    kq: i32,

    fn handle_sigint(_: i32) callconv(.c) void {
        restore_terminal();
        std.c.exit(1);
    }

    fn restore_terminal() callconv(.c) void {
        const res = std.c.tcsetattr(
            std.c.STDIN_FILENO,
            .NOW,
            &original_termios
        );
        if (res != 0) @panic("Failed to restore terminal! Please reopen this window.");
    }

    fn save_termios() Errors!void {
        const res = std.c.tcgetattr(std.c.STDIN_FILENO, &original_termios);
        if (res != 0) return error.InvalidOs;
        const atexit_res = libc.atexit(restore_terminal);
        if (atexit_res != 0) return error.InvalidOs;
        const signal_res = libc.signal(std.c.SIG.INT, handle_sigint);
        if (signal_res == std.c.SIG.ERR) return error.InvalidOs;
    }

    const VMIN = 4;
    const VTIME = 5;
    fn set_raw_terminal() Errors!void {
        var raw = original_termios;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[VMIN] = 0;
        raw.cc[VTIME] = 0;
        const res = std.c.tcsetattr(
            std.c.STDIN_FILENO,
            .NOW,
            &raw
        );
        if (res != 0) return error.InvalidOs;
    }

    fn init_watcher() Errors!i32 {
        const kq = std.c.kqueue();
        if (kq < 0) {
            return error.FailedToWatchFile;
        }
        return kq;
    }

    fn add_file_watcher(event: *std.c.Kevent, buffer: []u8) Errors!void {
        const fd = std.c.open(@as([*:0]u8, @ptrCast(buffer)), .{.EVTONLY = true});
        if (fd <= 0) {
            return error.FailedToWatchFile;
        }
        const vnode_events: u32 = std.c.NOTE.WRITE;
        event.ident = @intCast(fd);
        event.filter = std.c.EVFILT.VNODE;
        event.flags = std.c.EV.ADD | std.c.EV.CLEAR;
        event.fflags = vnode_events;
        event.data = 0;
        event.udata = 0;
    }

    pub fn setup(task_id: TaskId, io: IO) Errors!LogFileListener {
        try io.save_termios();
        try io.set_raw_terminal();

        var events_to_monitor: [NUM_EVENTS_TO_MONITOR]std.c.Kevent = std.mem.zeroes([NUM_EVENTS_TO_MONITOR]std.c.Kevent);

        const kq = try io.init_watcher();

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        var bw = std.io.bufferedWriter(fbs.writer());
        const bw_writer = &bw.writer();

        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        try PathBuilder.add_tasks_dir(bw_writer);
        try PathBuilder.add_task_dir(bw_writer, task_id);
        try PathBuilder.add_task_file(bw_writer, "stdout");
        try PathBuilder.add_terminator(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.FailedToWatchFile);

        try io.add_file_watcher(&events_to_monitor[0], &buffer);

        fbs.reset();
        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        try PathBuilder.add_tasks_dir(bw_writer);
        try PathBuilder.add_task_dir(bw_writer, task_id);
        try PathBuilder.add_task_file(bw_writer, "stderr");
        try PathBuilder.add_terminator(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.FailedToWatchFile);

        try io.add_file_watcher(&events_to_monitor[1], &buffer);

        // STDIN
        events_to_monitor[2].ident = std.c.STDIN_FILENO;
        events_to_monitor[2].filter = std.c.EVFILT.READ;
        events_to_monitor[2].flags = std.c.EV.ADD | std.c.EV.CLEAR;
        events_to_monitor[2].fflags = 0;
        events_to_monitor[2].data = 0;
        events_to_monitor[2].udata = 0;

        return .{
            .kq = kq,
            .events_to_monitor = events_to_monitor,
            .event_data = std.mem.zeroes([NUM_EVENTS]std.c.Kevent)
        };
    }

    fn poll_watcher(self: *LogFileListener) Errors!void {
        const event_count = std.c.kevent(
            self.kq,
            &self.events_to_monitor,
            NUM_EVENTS_TO_MONITOR,
            @as([*]std.c.Kevent, @ptrCast(&self.event_data)),
            NUM_EVENTS,
            null
        );
        if (event_count < 0) {
            return error.FailedToWatchFile;
        }
    }

    fn read_stdin_byte() Errors!u8 {
        const stdin_reader = std.io.getStdIn().reader();
        const byte = stdin_reader.readByte()
            catch |err| return e.verbose_error(err, error.FailedToWatchFile);
        return byte;
    }

    pub fn read(self: *LogFileListener, io: IO) Errors!?tf.StdLogFileEvent {
        try io.poll_watcher(self);

        if (self.event_data[0].ident == std.c.STDIN_FILENO) {
            const byte = try io.read_stdin_byte();
            if (byte == 'q') {
                return null;
            }
            return .skip;
        }

        // STDOUT
        if (self.event_data[0].ident == self.events_to_monitor[0].ident) {
            return .out;
        }
        // STDERR
        if (self.event_data[0].ident == self.events_to_monitor[1].ident) {
            return .err;
        }

        return error.FailedToWatchFile;
    }

    fn deinit_watcher(self: *LogFileListener) void {
        _ = std.c.close(@intCast(self.events_to_monitor[0].ident));
        _ = std.c.close(@intCast(self.events_to_monitor[1].ident));
        _ = std.c.close(@intCast(self.kq));
    }

    pub fn close(self: *LogFileListener, io: IO) Errors!void {
        io.deinit_watcher(self);
    }
};
