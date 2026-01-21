const std = @import("std");
const flute = @import("flute");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const libc = @import("../c.zig").libc;

const LinuxProcess = @import("./process.zig").LinuxProcess;
const util = @import("../util.zig");
const PathBuilder = @import("../file.zig").PathBuilder;

const t = @import("../task/index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const tf = @import("../task/file.zig");

const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const e = @import("../error.zig");
const Errors = e.Errors;
const log = @import("../log.zig");
const MULTASK_TASK_ID = [_]u8 {
    0, 'M', 'U', 'L', 'T', 'A', 'S', 'K', '_', 'T', 'A', 'S', 'K', '_', 'I', 'D', '='
};

pub const TaskReadProcess = struct {
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
        
    pub fn init(proc: *const LinuxProcess) TaskReadProcess {
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

    pub fn init(proc: *const LinuxProcess, task_proc: TaskReadProcess, children: ?[]ReadProcess) ReadProcess {
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

pub const ProcFs = struct {
    /// Gets all stats from the /proc/pid/stat file.
    /// More info, use `man proc` and go to /proc/pid/stat
    pub const Stats = struct {
        val: [][]u8,

        pub fn deinit(self: *const Stats) void {
            defer {
                for (self.val) |stat| {
                    util.gpa.free(stat);
                }
                util.gpa.free(self.val);
            }
        }
    };

    var ARG_MAX: i64 = -1;

    pub const FileType = enum {
        Children,
        Stat,
        Comm,
        Status,
        Statm,
        Environ,

        RootStat,
        RootUptime,
        RootLoadavg
    };

    /// FREE THIS
    pub fn read_file(pid: ?Pid, comptime file_type: FileType) Errors![]u8 {
        if (pid == null) {
            return switch (file_type) {
                // FileType.RootUptime => try read_root_uptime(),
                // FileType.RootLoadavg => try read_root_loadavg(),
                else => @panic("No support for reading into buf for this file.")
            };
        } else {
            return switch (file_type) {
                FileType.Children => try read_pid_children(pid.?),
                FileType.Environ => try read_pid_environ(pid.?),
                // FileType.Stat => try read_pid_stat(pid.?),
                // FileType.Comm => try read_pid_comm(pid.?),
                // FileType.Statm => try read_pid_statm(pid.?),
                else => @panic("No support for reading into buf for this file.")
            };
        }
    }

    pub fn read_file_until_delimiter_buf(pid: ?Pid, buf: []u8, delimiter: u8, comptime file_type: FileType) Errors![]const u8 {
        if (pid == null) {
            return switch (file_type) {
                FileType.RootStat => try read_root_stat_until_delimiter_buf(buf, delimiter),
                else => @panic("No support for reading into buf for this file.")
            };
        } else {
            return switch (file_type) {
                else => @panic("No support for reading into buf for this file.")
            };
        }
    }

    /// Recommended buf size: 4096
    fn read_root_stat_until_delimiter_buf(buf: []u8, delimiter: u8) Errors![]const u8 {
        try log.printdebug("Reading /proc/stat", .{});
        const stat_file = std.fs.openFileAbsolute("/proc/stat", .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetRootStats
            });
        defer stat_file.close();

        var buf_reader = std.io.bufferedReader(stat_file.reader());
        var br = &buf_reader.reader();

        const bytes_written = br.read(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetRootStats);
        const res = get_slice_until_delimiter(buf[0..bytes_written], 0, delimiter);
        if (res == null) {
            return error.FailedToGetRootStats;
        }
        return res.?;
    }

    pub fn read_file_buf(pid: ?Pid, buf: []u8, comptime file_type: FileType) Errors![]u8 {
        if (pid == null) {
            return switch (file_type) {
                FileType.RootUptime => try read_root_uptime_buf(buf),
                FileType.RootLoadavg => try read_root_loadavg_buf(buf),
                else => @panic("No support for reading into buf for this file.")
            };
        } else {
            return switch (file_type) {
                FileType.Comm => try read_pid_comm_buf(pid.?, buf),
                FileType.Stat => try read_pid_stat_buf(pid.?, buf),
                FileType.Statm => try read_pid_statm_buf(pid.?, buf),
                FileType.Environ => try read_pid_environ_buf(pid.?, buf),
                // Children should not be buf'd because there is no maximum number of processes
                // FileType.Children => try read_pid_children_buf(pid.?, buf),
                else => @panic("No support for reading into buf for this file.")
            };
        }
    }

    /// Recommended buf size: 128
    fn read_root_uptime_buf(buf: []u8) Errors![]u8 {
        // try log.printdebug("Reading /proc/uptime", .{});
        const uptime_file = std.fs.openFileAbsolute("/proc/uptime", .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetSystemUptime
            });
        defer uptime_file.close();

        const bytes_written = uptime_file.reader().readAll(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return buf[0..bytes_written];
    }

    /// Recommended buf size: 128
    fn read_root_loadavg_buf(buf: []u8) Errors![]u8 {
        // try log.printdebug("Reading /proc/loadavg", .{});
        const loadavg_file = std.fs.openFileAbsolute("/proc/loadavg" , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessComm
            });
        defer loadavg_file.close();
        const bytes_written = loadavg_file.reader().readAll(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);

        return buf[0..bytes_written];
    }

    /// Recommended buf size: 4096
    fn read_pid_comm_buf(pid: Pid, buf: []u8) Errors![]u8 {
        // try log.printdebug("Reading /proc/{d}/comm", .{pid});
        var path_buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        const comm_file = std.fs.openFileAbsolute(comm_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessComm
            });
        defer comm_file.close();

        var buf_reader = std.io.bufferedReader(comm_file.reader());
        var br = &buf_reader.reader();

        const bytes_written = br.read(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return buf[0..bytes_written];
    }

    /// Recommended buf size: 4096
    fn read_pid_stat_buf(pid: Pid, buf: []u8) Errors![]u8 {
        // try log.printdebug("Reading /proc/{d}/stat", .{pid});
        var path_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
        const stat_file = std.fs.openFileAbsolute(stat_path, .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessStats
            });
        defer stat_file.close();

        var buf_reader = std.io.bufferedReader(stat_file.reader());
        var br = &buf_reader.reader();

        const bytes_written = br.read(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return buf[0..bytes_written];
    }

    /// Recommended buf size: 128
    fn read_pid_statm_buf(pid: Pid, buf: []u8) Errors![]u8 {
        // try log.printdebug("Reading /proc/{d}/statm", .{pid});
        var path_buf: [64]u8 = undefined;
        const pid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/statm", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessMemory);
        const statm_file = std.fs.openFileAbsolute(pid_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer statm_file.close();

        var buf_reader = std.io.bufferedReader(statm_file.reader());
        var br = &buf_reader.reader();

        const bytes_written = br.readAll(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return buf[0..bytes_written];
    }

    /// Recommended buf size: 2 MB - Do not use this if you're going
    /// to keep this in the stack for long
    fn read_pid_environ_buf(pid: Pid, buf: []u8) Errors![]u8 {
        // try log.printdebug("Reading /proc/{d}/environ", .{pid});
        var path_buf: [64]u8 = undefined;
        const env_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        const env_file = std.fs.openFileAbsolute(env_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetEnvs
            });
        defer env_file.close();

        var buf_reader = std.io.bufferedReader(env_file.reader());
        var br = &buf_reader.reader();

        const bytes_written = br.readAll(buf)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        return buf[0..bytes_written];
    }

    fn read_pid_environ(pid: Pid) Errors![]u8 {
        // try log.printdebug("Reading /proc/{d}/environ", .{pid});
        var path_buf: [64]u8 = undefined;
        const env_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        const env_file = std.fs.openFileAbsolute(env_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetEnvs
            });
        defer env_file.close();
        if (ARG_MAX == -1) {
            ARG_MAX = libc.sysconf(libc._SC_ARG_MAX);
            if (ARG_MAX == -1) {
                ARG_MAX = 32000;
            }
        }

        var content_buf = util.gpa.alloc(u8, @intCast(ARG_MAX))
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        const bytes_written = env_file.read(content_buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        const content = content_buf[0..bytes_written];

        return content;
    }

    fn read_pid_children(pid: Pid) Errors![]u8 {
        // try log.printdebug("Reading /proc/{d}/children", .{pid});
        var path_buf: [128]u8 = undefined;
        const children_path = std.fmt.bufPrint(
            &path_buf, "/proc/{d}/task/{d}/children", .{ pid, pid }
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        const children_file = std.fs.openFileAbsolute(children_path, .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessChildren
            });
        defer children_file.close();

        const content_buf = util.gpa.alloc(u8, 32000)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        const bytes_written = children_file.read(content_buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        return content_buf[0..bytes_written];
    }

    /// Get all entries in /proc
    pub fn get_procs() Errors![]Pid {
        var dir = std.fs.openDirAbsolute("/proc", .{.iterate = true})
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
        if (dir == null) {
            return error.FailedToGetAllProcesses;
        }
        defer dir.?.close();

        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();

        var dir_itr = dir.iterate();
        while (
            dir_itr.next()
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses)
        ) |entry| {
            if (entry.kid != .directory) {
                continue;
            }

            const pid = std.fmt.parseInt(util.Pid, entry.name, 10)
                catch continue;

            pids.append(pid)
                catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
        }

        return pids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
    }

    /// Get all children in /proc/pid/task/pid/children
    pub fn get_proc_children(pid: Pid) Errors![]Pid {
        var child_pids = std.ArrayList(Pid).init(util.gpa);
        defer child_pids.deinit();

        const content = read_file(pid, FileType.Children)
            catch |err| switch (err) {
                error.ProcessFileNotFound => return &[0]i32{},
                else => return err
        };
        defer util.gpa.free(content);
        var str_child_pids = std.mem.splitScalar(u8, content, ' ');

        while (str_child_pids.next()) |str| {
            if (str.len == 0)
                continue;
            const child_pid = std.fmt.parseInt(Pid, str, 10)
                catch return error.FailedToGetProcessChildren;
            child_pids.append(child_pid)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        }

        return child_pids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
    }

    fn get_slice_until_delimiter(content: []const u8, start_idx: usize, delimiter: u8) ?[]const u8 {
        var idx = start_idx;

        while (idx < content.len and content[idx] != delimiter) {
            idx = idx + 1;
        }

        if (idx == start_idx) {
            return null;
        }

        return content[start_idx..idx];
    }

    fn trim_whitespace(content: []const u8) []const u8 {
        var start_idx: usize = 0;
        var end_idx: usize = content.len;
        if (content.len == 0) {
            return content;
        }
        if (content[0] == '\n') {
            start_idx += 1;
        }
        if (content[content.len - 1] == '\n') {
            end_idx -= 1;
        }
        return content[start_idx..end_idx];
    }

    pub fn extract_stat_buf(buf: []u8, content: []const u8, index: usize) Errors!?[]u8 {
        var bracket_count: i32 = 0;
        var property_idx: usize = 0;
        var property_cursor: usize = 0;
        var property_buf: [4096]u8 = undefined;
        var start_idx: usize = 0;
        while (get_slice_until_delimiter(content, start_idx, ' ')) |pstat| {
            start_idx += pstat.len + 1;
            // const stat = std.mem.trim(u8, pstat, "\n");
            const stat = trim_whitespace(pstat);
            if (stat[0] == '(') {
                bracket_count += 1;
            }
            if (stat[stat.len - 1] == ')') {
                bracket_count -= 1;
            }
            if (bracket_count > 0) {
                @memcpy(property_buf[property_cursor..stat.len + property_cursor], stat);
                property_cursor += stat.len;

                property_buf[property_cursor] = ' ';
                property_cursor += 1;
            }

            if (bracket_count == 0) {
                @memcpy(property_buf[property_cursor..stat.len + property_cursor], stat);
                property_cursor += stat.len;
                if (property_idx == index) {
                    const stat_str = property_buf[0..property_cursor];
                    @memcpy(buf[0..stat_str.len], stat_str);
                    return buf[0..stat_str.len];
                }
                property_cursor = 0;
                property_idx += 1;
            }

        }
        return null;
    }

    pub fn get_process_stat_buf(buf: []u8, pid: Pid, index: usize) Errors!?[]u8 {
        var content_buf: [4096]u8 = undefined;
        const content = try read_file_buf(pid, &content_buf, FileType.Stat);

        return try extract_stat_buf(buf, content, index);
    }

    pub fn get_process_stats(
        pid: Pid
    ) Errors!Stats {
        var buf: [4096]u8 = undefined;
        const content = try read_file_buf(pid, &buf, FileType.Stat);

        return try parse_linux_file(content, null);
    }

    /// Parses /proc/pid/stat and /proc/loadavg file or just any string separated file.
    fn parse_linux_file(content: []u8, limit: ?u8) Errors!Stats {
        var stats = std.ArrayList([]u8).init(util.gpa);
        defer stats.deinit();
        var stat_line = std.ArrayList([]u8).init(util.gpa);
        defer stat_line.deinit();

        var str_stats = std.mem.splitScalar(u8, content, ' ');

        var bracket_count: i32 = 0;
        while (str_stats.next()) |pstat| {
            if (limit != null and stats.items.len == limit.?) {
                break;
            }
            const trimmed_pstat = std.mem.trim(u8, pstat, "\n");
            const stat = try util.strdup(trimmed_pstat, error.FailedToGetProcessStats);
            if (stat[0] == '(') {
                bracket_count += 1;
            }
            if (stat[stat.len - 1] == ')') {
                bracket_count -= 1;
                if (bracket_count == 0) {
                    stat_line.append(stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                }
            }
            if (bracket_count > 0) {
                stat_line.append(stat)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
            }

            if (bracket_count == 0) {
                if (stat_line.capacity == 0) {
                    stats.append(stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                } else {
                    const str_stat = std.mem.join(util.gpa, " ", stat_line.items)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                    stats.append(str_stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);

                    for (stat_line.items) |item| {
                        util.gpa.free(item);
                    }
                    stat_line.clearAndFree();
                }
            }
        }

        return Stats {
            .val = stats.toOwnedSlice()
                catch |err| return e.verbose_error(err, error.FailedToGetProcessStats)
        };
    }

    pub fn get_procs_dir() Errors!std.fs.Dir {
        const dir = std.fs.openDirAbsolute("/proc", .{.iterate = true})
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
        return dir;
    }

    pub fn proc_has_taskid_in_env(pid: Pid, task_id: TaskId) bool {
        const env_block = read_file(pid, FileType.Environ) catch return false;
        defer util.gpa.free(env_block);

        const envtask_id = find_task_id_from_env_block(env_block) catch return false;

        return envtask_id != null and envtask_id.? == task_id;
    }

    pub fn find_task_id_from_env_block(env_block: []u8) Errors!?TaskId {
        const idx = std.mem.indexOf(u8, env_block, &MULTASK_TASK_ID);
        if (idx == null) {
            return null;
        }
        const start_idx = idx.? + MULTASK_TASK_ID.len;
        var end_idx = idx.? + MULTASK_TASK_ID.len;
        while (env_block[end_idx] != 0) {
            if (end_idx > start_idx + 10) {
                return error.CorruptTaskIdEnvVariable;
            }
            end_idx += 1;
        }

        const trimmed_str_task_id = std.mem.trimRight(u8, env_block[start_idx..end_idx], &[1]u8{0});

        const envtask_id = std.fmt.parseInt(TaskId, trimmed_str_task_id, 10)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        return envtask_id;
    }
};

const IN_NONBLOCK = 0o4000;
const IN_DONT_FOLLOW = 0x02000000;
const IN_ATTRIB = 0x00000004;

const IN_MODIFY = 0x00000002;
const IN_DELETE_SELF = 0x00000400;
const IN_CLOSE_NOWRITE = 0x00000010;
const WATCH_FLAGS = IN_MODIFY | IN_ATTRIB;

const VMIN = 4;
const VTIME = 5;
pub const LogFileListener = struct {
    var original_termios: std.c.termios = std.mem.zeroes(std.c.termios);
    /// This is here for testing.
    /// These functions contain libc things and that's not realistic to test.
    pub const IO = struct {
        save_termios: fn () Errors!void,
        set_raw_terminal: fn () Errors!void,
        init_watcher: fn () Errors!i32,
        add_file_watcher: fn (fd: i32, buffer: []u8) Errors!i32,
        poll_watcher: fn (fds: []std.c.pollfd) Errors!void,
        read_stdin_byte: fn () Errors!u8,
        read_log_file_event: fn (self: *const LogFileListener) Errors!?tf.StdLogFileEvent,
        deinit_watcher: fn (self: *const LogFileListener) Errors!void,
    };
    pub const MainIO: IO = .{
        .save_termios = LogFileListener.save_termios,
        .set_raw_terminal = LogFileListener.set_raw_terminal,
        .init_watcher = LogFileListener.init_watcher,
        .add_file_watcher = LogFileListener.add_file_watcher,
        .poll_watcher = LogFileListener.poll_watcher,
        .read_stdin_byte = LogFileListener.read_stdin_byte,
        .read_log_file_event = LogFileListener.read_log_file_event,
        .deinit_watcher = LogFileListener.deinit_watcher,
    };

    fn init_watcher() Errors!i32 {
        const fd: i32 = @intCast(std.c.inotify_init1(0));
        if (fd == 0) {
            return error.FailedToWatchFile;
        }
        return fd;
    }

    fn add_file_watcher(fd: i32, buffer: []u8) Errors!i32 {
        const wd: i32 = @intCast(std.c.inotify_add_watch(fd, @as([*:0]u8, @ptrCast(buffer)), WATCH_FLAGS));
        if (wd == -1) {
            return error.FailedToWatchFile;
        }
        return wd;
    }

    fn poll_watcher(fds: []std.c.pollfd) Errors!void {
        const events_written = std.c.poll(fds.ptr, fds.len, -1);
        if (events_written > fds.len or events_written < 0) {
            return error.FailedToWatchFile;
        }
    }

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

    inotify_fd: i32,
    wd_out: i32,
    wd_err: i32,

    pub fn setup(task_id: TaskId, io: IO) Errors!LogFileListener {
        try io.save_termios();
        try io.set_raw_terminal();

        const fd = try io.init_watcher();

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

        const wd_out = try io.add_file_watcher(fd, &buffer);

        fbs.reset();
        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        try PathBuilder.add_tasks_dir(bw_writer);
        try PathBuilder.add_task_dir(bw_writer, task_id);
        try PathBuilder.add_task_file(bw_writer, "stderr");
        try PathBuilder.add_terminator(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.FailedToWatchFile);

        const wd_err = try io.add_file_watcher(fd, &buffer);

        return .{
            .inotify_fd = fd,
            .wd_out = wd_out,
            .wd_err = wd_err,
        };
    }

    fn read_stdin_byte() Errors!u8 {
        const stdin_reader = std.io.getStdIn().reader();
        const byte = stdin_reader.readByte()
            catch |err| return e.verbose_error(err, error.FailedToWatchFile);
        return byte;
    }

    fn read_log_file_event(self: *const LogFileListener) Errors!?tf.StdLogFileEvent {
        var event_buf: [1024]u8 = std.mem.zeroes([1024]u8);

        const bytes_read = std.c.read(self.inotify_fd, &event_buf, 1024);
        if (bytes_read == 0 or bytes_read > 1024) {
            return null;
        }

        const event: *align(1) std.os.linux.inotify_event = std.mem.bytesAsValue(std.os.linux.inotify_event, &event_buf);

        if ((event.mask & IN_ATTRIB) == IN_ATTRIB) {
            return error.TaskFileFailedRead;
        }

        if (event.wd == self.wd_out) return .out;
        if (event.wd == self.wd_err) return .err;

        return error.FailedToWatchFile;
    }

    pub fn read(self: *const LogFileListener, io: IO) Errors!?tf.StdLogFileEvent {
        var fds = [_]std.c.pollfd{
            .{.fd = std.c.STDIN_FILENO, .events = std.c.POLL.IN, .revents = 0},
            .{.fd = self.inotify_fd, .events = std.c.POLL.IN, .revents = 0},
        };

        try io.poll_watcher(&fds);

        if ((fds[0].revents & std.c.POLL.IN) == std.c.POLL.IN) {
            const byte = try io.read_stdin_byte();
            if (byte == 'q') {
                return null;
            }
            return .skip;
        } else if ((fds[1].revents & std.c.POLL.IN) == std.c.POLL.IN) {
            return try io.read_log_file_event(self);
        }

        return error.FailedToWatchFile;
    }

    fn deinit_watcher(self: *const LogFileListener) Errors!void {
        const out_res = std.c.inotify_rm_watch(self.inotify_fd, self.wd_out);
        if (out_res != 0) {
            return error.FailedToWatchFile;
        }
        const err_res = std.c.inotify_rm_watch(self.inotify_fd, self.wd_err);
        if (err_res != 0) {
            return error.FailedToWatchFile;
        }
        _ = std.c.close(self.inotify_fd);
    }

    pub fn close(self: *const LogFileListener, io: IO) Errors!void {
        try io.deinit_watcher(self);
    }
};

test "lib/linux/file.zig" {
    std.debug.print("\n--- lib/linux/file.zig ---\n", .{});
}

test "LogFileListener save_termios called" {
    std.debug.print("LogFileListener save_termios called\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void { return error.TestFunctionCalled; }
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void {}
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 { return 1; }
        }.init_watcher,
        .add_file_watcher = struct {
            fn add_file_watcher(_: i32, _: []u8) Errors!i32 { return 1; }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(_: []std.c.pollfd) Errors!void {}
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 { return 0; }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {return null;}
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    try expectError(error.TestFunctionCalled, LogFileListener.setup(1, test_io));
}

test "LogFileListener set_raw_terminal called" {
    std.debug.print("LogFileListener set_raw_terminal called\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void {}
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void { return error.TestFunctionCalled; }
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 { return 1; }
        }.init_watcher,
        .add_file_watcher = struct {
            fn add_file_watcher(_: i32, _: []u8) Errors!i32 { return 1; }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(_: []std.c.pollfd) Errors!void {}
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 { return 0; }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {return null;}
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    try expectError(error.TestFunctionCalled, LogFileListener.setup(1, test_io));
}

test "LogFileListener no event written failure" {
    std.debug.print("LogFileListener no event written failure\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void {}
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void {}
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 {
                return 1;
            }
        }.init_watcher,
        .add_file_watcher = struct {
            fn add_file_watcher(_: i32, _: []u8) Errors!i32 { return 1; }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(_: []std.c.pollfd) Errors!void {}
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 {
                return 0;
            }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {
                return .out;
            }
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    const lis = try LogFileListener.setup(1, test_io);
    try expectError(error.FailedToWatchFile, lis.read(test_io));
}

test "LogFileListener stderr log success" {
    std.debug.print("LogFileListener stderr log success\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void {}
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void {}
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 {
                return 1;
            }
        }.init_watcher,
        .add_file_watcher = struct {
            var file_watcher_counter: u8 = 0;
            fn add_file_watcher(fd: i32, buf: []u8) Errors!i32 {
                file_watcher_counter += 0;
                expect(fd == 1) catch return error.TestExpectFailed;
                if (file_watcher_counter == 1) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stdout")) catch return error.TestExpectFailed;
                }
                if (file_watcher_counter == 2) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stderr")) catch return error.TestExpectFailed;
                }
                return file_watcher_counter;
            }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(fds: []std.c.pollfd) Errors!void {
                fds[1].revents |= std.c.POLL.IN;
            }
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 {
                return 0;
            }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {
                return .err;
            }
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    const lis = try LogFileListener.setup(1, test_io);

    const res = try lis.read(test_io);

    try lis.close(test_io);
    try expect(res.? == .err);
}

test "LogFileListener stdout log success" {
    std.debug.print("LogFileListener stdout log success\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void {}
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void {}
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 {
                return 1;
            }
        }.init_watcher,
        .add_file_watcher = struct {
            var file_watcher_counter: u8 = 0;
            fn add_file_watcher(fd: i32, buf: []u8) Errors!i32 {
                file_watcher_counter += 0;
                expect(fd == 1) catch return error.TestExpectFailed;
                if (file_watcher_counter == 1) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stdout")) catch return error.TestExpectFailed;
                }
                if (file_watcher_counter == 2) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stderr")) catch return error.TestExpectFailed;
                }
                return file_watcher_counter;
            }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(fds: []std.c.pollfd) Errors!void {
                fds[1].revents |= std.c.POLL.IN;
            }
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 {
                return 0;
            }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {
                return .out;
            }
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    const lis = try LogFileListener.setup(1, test_io);

    const res = try lis.read(test_io);

    try lis.close(test_io);
    try expect(res.? == .out);
}

test "LogFileListener stdin q character success" {
    std.debug.print("LogFileListener stdin q character success\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void {}
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void {}
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 {
                return 1;
            }
        }.init_watcher,
        .add_file_watcher = struct {
            var file_watcher_counter: u8 = 0;
            fn add_file_watcher(fd: i32, buf: []u8) Errors!i32 {
                file_watcher_counter += 0;
                expect(fd == 1) catch return error.TestExpectFailed;
                if (file_watcher_counter == 1) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stdout")) catch return error.TestExpectFailed;
                }
                if (file_watcher_counter == 2) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stderr")) catch return error.TestExpectFailed;
                }
                return file_watcher_counter;
            }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(fds: []std.c.pollfd) Errors!void {
                fds[0].revents |= std.c.POLL.IN;
            }
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 {
                return 'q';
            }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {
                std.debug.print("This should not be called.\n", .{});
                expect(false) catch return error.TestExpectFailed;
                return null;
            }
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    const lis = try LogFileListener.setup(1, test_io);

    const res = try lis.read(test_io);

    try lis.close(test_io);
    try expect(res == null);
}

test "LogFileListener stdin non q character success" {
    std.debug.print("LogFileListener stdin non q character success\n", .{});
    const test_io = LogFileListener.IO{
        .save_termios = struct {
            fn save_termios() Errors!void {}
        }.save_termios,
        .set_raw_terminal = struct {
            fn set_raw_terminal() Errors!void {}
        }.set_raw_terminal,
        .init_watcher = struct {
            fn init_watcher() Errors!i32 {
                return 1;
            }
        }.init_watcher,
        .add_file_watcher = struct {
            var file_watcher_counter: u8 = 0;
            fn add_file_watcher(fd: i32, buf: []u8) Errors!i32 {
                file_watcher_counter += 0;
                expect(fd == 1) catch return error.TestExpectFailed;
                if (file_watcher_counter == 1) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stdout")) catch return error.TestExpectFailed;
                }
                if (file_watcher_counter == 2) {
                    expect(std.mem.eql(u8, buf, "/test/home/.multi-tasker-test/tasks/1/stderr")) catch return error.TestExpectFailed;
                }
                return file_watcher_counter;
            }
        }.add_file_watcher,
        .poll_watcher = struct {
            fn poll_watcher(fds: []std.c.pollfd) Errors!void {
                fds[0].revents |= std.c.POLL.IN;
            }
        }.poll_watcher,
        .read_stdin_byte = struct {
            fn read_stdin_byte() Errors!u8 {
                return ' ';
            }
        }.read_stdin_byte,
        .read_log_file_event = struct {
            fn read_log_file_event(_: *const LogFileListener) Errors!?tf.StdLogFileEvent {
                std.debug.print("This should not be called.\n", .{});
                expect(false) catch return error.TestExpectFailed;
                return null;
            }
        }.read_log_file_event,
        .deinit_watcher = struct {
            fn deinit_watcher(_: *const LogFileListener) Errors!void {}
        }.deinit_watcher
    };

    const lis = try LogFileListener.setup(1, test_io);

    const res = try lis.read(test_io);

    try lis.close(test_io);
    try expect(res.? == .skip);
}

test "Parse linux /proc/pid/stat file contents" {
    std.debug.print("Parse linux /proc/pid/stat file contents\n", .{});

    const content = try std.fmt.allocPrint(util.gpa, "1 (test program) S 2 3", .{});
    defer util.gpa.free(content);
    
    var stats = try ProcFs.parse_linux_file(content, 5);
    defer stats.deinit();

    try expect(std.mem.eql(u8, stats.val[0], "1"));
    try expect(std.mem.eql(u8, stats.val[1], "(test program)"));
    try expect(std.mem.eql(u8, stats.val[2], "S"));
    try expect(std.mem.eql(u8, stats.val[3], "2"));
    try expect(std.mem.eql(u8, stats.val[4], "3"));
}

test "Parse linux /proc/loadavg file contents" {
    std.debug.print("Parse linux /proc/loadavg file contents\n", .{});

    const content = try std.fmt.allocPrint(util.gpa, "2.35 2.07 1.60 1/1535 34838\n", .{});
    defer util.gpa.free(content);
    
    var stats = try ProcFs.parse_linux_file(content, 5);
    defer stats.deinit();

    try expect(std.mem.eql(u8, stats.val[0], "2.35"));
    try expect(std.mem.eql(u8, stats.val[1], "2.07"));
    try expect(std.mem.eql(u8, stats.val[2], "1.60"));
    try expect(std.mem.eql(u8, stats.val[3], "1/1535"));
    try expect(std.mem.eql(u8, stats.val[4], "34838"));
}

test "Parse linux /proc/pid/environ file contents" {
    std.debug.print("Parse linux /proc/pid/environ file contents\n", .{});
    const content = try std.fmt.allocPrint(util.gpa, "KEY=VAL\x00KEY2=VAL2\x00MULTASK_TASK_ID=15\x00KEY3=VAL3\x00", .{});
    defer util.gpa.free(content);

    const task_id = try ProcFs.find_task_id_from_env_block(content);
    try expect(task_id != null and task_id == 15);
}

test "Get single stat in brackets from /proc/pid/stat file contents with buffer" {
    std.debug.print("Get single stat in brackets from /proc/pid/stat file contents with buffer\n", .{});
    const content = "1 (test program) S 2 3";

    var buf: [4096]u8 = undefined;
    const res = try ProcFs.extract_stat_buf(&buf, content, 1);

    try expect(res != null);
    try expect(std.mem.eql(u8, res.?, "(test program)"));
}

test "Get single stat from /proc/pid/stat file contents with buffer" {
    std.debug.print("Get single stat from /proc/pid/stat file contents with buffer\n", .{});
    const content = "1 (test program) S 2 3";

    var buf: [4096]u8 = undefined;
    const res = try ProcFs.extract_stat_buf(&buf, content, 2);

    try expect(res != null);
    try expect(std.mem.eql(u8, res.?, "S"));
}

test "Get out of range stat from /proc/pid/stat file contents with buffer" {
    std.debug.print("Get out of range stat from /proc/pid/stat file contents with buffer\n", .{});
    const content = "1 (test program) S 2 3";

    var buf: [4096]u8 = undefined;
    const res = try ProcFs.extract_stat_buf(&buf, content, 10);

    try expect(res == null);
}

test "Get single stat from /proc/loadavg file contents with buffer" {
    std.debug.print("Get single stat from /proc/loadavg file contents with buffer\n", .{});
    const content = "0.78 0.92 0.96 1/1514 51068";

    var buf: [4096]u8 = undefined;
    const res = try ProcFs.extract_stat_buf(&buf, content, 4);

    try expect(res != null);
    try expect(std.mem.eql(u8, res.?, "51068"));
}

test "Get single stat from /proc/loadavg file contents with newline with buffer" {
    std.debug.print("Get single stat from /proc/loadavg file contents with newline with buffer\n", .{});
    const content = "0.78 0.92 0.96 1/1514\n \n51068";

    var buf: [4096]u8 = undefined;
    const res = try ProcFs.extract_stat_buf(&buf, content, 4);

    try expect(res != null);
    try expect(std.mem.eql(u8, res.?, "51068"));
}
