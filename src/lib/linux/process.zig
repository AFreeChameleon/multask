const std = @import("std");
const libc = @import("../c.zig").libc;
const log = @import("../log.zig");
const util = @import("../util.zig");
const Pid = util.Pid;
const Lengths = util.Lengths;
const FileStrings = util.FileStrings;
const e = @import("../error.zig");
const Errors = e.Errors;
const Find = @import("../file.zig").Find;

const t = @import("../task/index.zig");
const TaskFiles = t.Files;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const Cpu = @import("./cpu.zig");
const LinuxCpu = Cpu.LinuxCpu;

const taskproc = @import("../task/process.zig");
const CpuStatus = taskproc.CpuStatus;

const r = @import("../task/resources.zig");
const Resources = r.Resources;
const JSON_Resources = r.JSON_Resources;

const f = @import("../task/file.zig");
const ReadProcess = f.ReadProcess;
const ProcessSection = f.ProcessSection;

pub const LinuxProcess = struct {
    const Self = @This();

    pid: Pid,
    task: *Task,
    start_time: u64,
    children: ?[]Self = null,
    memory_limit: util.MemLimit = 0,

    /// Only set start time to anything from a saved json file
    pub fn init(
        task: *Task,
        pid: Pid,
        starttime: ?u64
    ) Errors!Self {
        var proc = Self {
            .pid = pid,
            .task = task,
            .start_time = 0
        };
        if (starttime != null) {
            proc.start_time = starttime.?;
        } else if (proc.proc_exists()) {
            proc.start_time = try proc.get_starttime();
        }
        return proc;
    }

    pub fn deinit(self: Self) void {
        if (self.children != null) {
            util.gpa.free(self.children.?);
        }
    }

    pub fn monitor_stats(
        self: *Self,
    ) Errors!void {
        var keep_running = false;

        var children = std.ArrayList(Self).init(util.gpa);
        defer children.deinit();

        if (!self.proc_exists()) {
            // If main proc doesnt exist, read the saved child processes
            // if any of those exist, set the main process to the first one that's running?
            // should I do that? what if there are multiple child processes running alongside each other?
            // don't do it because I can just check saved processes and add it
            // to the children array and save them
            const saved_procs = try taskproc.get_running_saved_procs(self);
            defer util.gpa.free(saved_procs);
            if (saved_procs.len != 0) {
                keep_running = true;
            }
            for (saved_procs) |sproc| {
                var exists = false;
                for (children.items) |proc| {
                    if (
                        sproc.pid == proc.pid and
                        sproc.start_time == proc.start_time
                    ) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    children.append(
                        try Self.init(sproc.task, sproc.pid, sproc.start_time)
                    ) catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                    try self.get_children(&children, sproc.pid);
                }
            }
        } else {
            keep_running = true;
            try self.get_children(&children, self.pid);
        }

        self.children = children.items;
        defer self.children = null;
        try taskproc.check_memory_limit_within_limit(self);

        try taskproc.save_files(self);
        try LinuxCpu.update_time_total();
        if (!keep_running) {
            try taskproc.kill_all(self);
        }
    }

    pub fn any_proc_child_exists(self: *Self) bool {
        var children = std.ArrayList(Self).init(util.gpa);
        defer children.deinit();
        self.get_children(&children, self.pid)
            catch return false;
        for (children.items) |child| {
            var proc = Self.init(self.task, child.pid, null)
                catch continue;
            if (proc.proc_exists()) {
                return true;
            }
        }
        return false;
    }

    /// Gets command name associated with process.
    /// More info, use `man proc` and go to /proc/pid/comm
    pub fn get_exe(self: *Self) Errors![]const u8 {
        // Max size should be 255
        const comm_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/comm", .{self.pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        defer util.gpa.free(comm_path);
        const comm_file = std.fs.openFileAbsolute(comm_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        defer comm_file.close();

        var buf = std.mem.zeroes([libc.NAME_MAX]u8);
        var comm_file_reader = std.io.bufferedReader(comm_file.reader());
        var in_stream = comm_file_reader.reader();
        _ = in_stream.readAll(&buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return util.strdup(
            std.mem.trimRight(u8, &buf, &[2]u8{0, '\n'}), // File has a \n ending it
            error.FailedToGetProcessComm
        );
    }

    /// Gets all stats from the /proc/pid/stat file.
    /// More info, use `man proc` and go to /proc/pid/stat
    pub fn get_process_stats(
        self: *Self,
    ) Errors![][]u8 {
        var stats = std.ArrayList([]u8).init(util.gpa);
        defer stats.deinit();
        var stat_line = std.ArrayList(u8).init(util.gpa);
        defer stat_line.deinit();

        const stat_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/stat", .{self.pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
        defer util.gpa.free(stat_path);
        const stat_file = std.fs.openFileAbsolute(stat_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
        defer stat_file.close();

        var bracket_count: i32 = 0;
        var buf_reader = std.io.bufferedReader(stat_file.reader());
        var reader = buf_reader.reader();
        var buf: [Lengths.MEDIUM]u8 = std.mem.zeroes([Lengths.MEDIUM]u8);
        var buf_fbs = std.io.fixedBufferStream(&buf);
        while (
            true
        ) {
            reader.streamUntilDelimiter(buf_fbs.writer(), ' ', buf_fbs.buffer.len)
                catch |err| switch (err) {
                    error.NoSpaceLeft => break,
                    error.EndOfStream => break,
                    else => |inner_err| return e.verbose_error(
                        inner_err, error.FailedToGetProcessStats
                    )
                };
            const it = buf_fbs.getWritten();
            defer buf_fbs.reset();
            if (it.len == 0) {
                break;
            }

            const stat = util.gpa.dupe(u8, it)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            if (stat[0] == '(') {
                bracket_count += 1;
            }
            if (stat[stat.len - 1] == ')') {
                bracket_count -= 1;
                if (bracket_count == 0) {
                    stat_line.appendSlice(stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                    util.gpa.free(stat);
                }
            }
            if (bracket_count > 0) {
                stat_line.appendSlice(stat)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
            }

            if (bracket_count == 0) {
                if (stat_line.capacity == 0) {
                    stats.append(stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                } else {
                    stats.append(
                        stat_line.toOwnedSlice()
                            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats))
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats
                    );
                }

                stat_line.clearAndFree();
            }
        }

        return stats.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
    }

    /// Checks if process exists by checking the pid exists, and if it's a zombie process
    /// also checks if process has the same start time (for new processes with same pid)
    pub fn proc_exists(self: *Self) bool {
        if (self.pid == 0) return false;
        if (libc.kill(self.pid, 0) != 0) {
            return false;
        }
        // Can't check start time because it hasn't been set
        if (self.start_time != 0) {
            const starttime = self.get_starttime()
                catch return false;
            if (starttime != self.start_time) {
                return false;
            }
        }
        const state = self.get_process_state()
            catch return false;
        if (state != null and state.? == 'Z') {
            return false;
        }
        return true;
    }

    fn get_process_state(self: *Self) Errors!?u8 {
        const pid_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/status", .{self.pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessState);
        defer util.gpa.free(pid_path);
        const status_file = std.fs.openFileAbsolute(pid_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessState);
        defer status_file.close();

        var buf = std.mem.zeroes([Lengths.LARGE]u8);
        var pid_file_reader = std.io.bufferedReader(status_file.reader());
        var in_stream = pid_file_reader.reader();

        while (in_stream.readUntilDelimiterOrEof(&buf, '\n')
            catch return null) |line| {
            if (!std.mem.eql(u8, line[0..5], "State")) {
                continue;
            }
            var state_itr = std.mem.splitAny(u8, line, "\t ");
            _ = state_itr.next();
            const state_keyword = state_itr.next();
            if (state_keyword == null) {
                return error.FailedToGetProcessState;
            }
            return state_keyword.?[0];
        }
        return null;
    }

    pub fn get_memory(self: *Self) Errors!u64 {
        var buf: [Lengths.LARGE]u8 = undefined;
        const pid_path = std.fmt.bufPrint(&buf, "/proc/{d}/statm", .{self.pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessMemory);
        const statm_file = std.fs.openFileAbsolute(pid_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer statm_file.close();

        var pid_file_reader = std.io.bufferedReader(statm_file.reader());
        var in_stream = pid_file_reader.reader();

        // Whole line is very small
        var line: [Lengths.MEDIUM]u8 = undefined;
        _ = in_stream.readAll(&line)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessMemory);
        var itr = std.mem.splitAny(u8, &line, " ");
        _ = itr.next();
        const resident = itr.next();
        if (resident == null) {
            return error.FailedToGetProcessMemory;
        }
        const memory: u64 = std.fmt.parseInt(u64, resident.?, 10)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessMemory);
        const page_size: u64 = @intCast(libc.sysconf(libc._SC_PAGESIZE));
        return memory * page_size;
    }

    pub fn get_runtime(self: *Self) Errors!u64 {
        const secs_since_epoch: u64 = @intCast(std.time.timestamp());

        const stats = try self.get_process_stats();
        defer {
            for (stats) |s| {
                defer util.gpa.free(s);
            }
            defer util.gpa.free(stats);
        }
        const start_time = std.fmt.parseInt(u64, stats[21], 10)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);
        const uptime_file = std.fs.openFileAbsolute("/proc/uptime", .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);
        defer uptime_file.close();

        var buf: [Lengths.MEDIUM]u8 = undefined;
        _ = uptime_file.readAll(&buf)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);

        var split_str = std.mem.splitSequence(u8, &buf, " ");
        const secs_since_boot_str = split_str.next();
        if (secs_since_boot_str == null) {
            return error.FailedToGetProcessRuntime;
        }

        const secs_since_boot = std.fmt.parseInt(
            u64, secs_since_boot_str.?[0..secs_since_boot_str.?.len - 3], 10
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);

        const ticks_per_sec: u64 = @intCast(libc.sysconf(libc._SC_CLK_TCK));

        if (secs_since_epoch -
            (secs_since_boot - @divTrunc(start_time, ticks_per_sec)) < 0
        ) {
            return error.FailedToGetProcessRuntime;
        }
        const runtime: u64 = secs_since_epoch -
            (secs_since_boot - @divTrunc(start_time, ticks_per_sec));

        return secs_since_epoch - runtime;
    }

    pub fn get_starttime(self: *Self) Errors!u64 {
        const stats = try self.get_process_stats();
        defer {
            for (stats) |stat| {
                util.gpa.free(stat);
            }
            util.gpa.free(stats);
        }
        const starttime_str = stats[21];
        const starttime: u64 = std.fmt.parseInt(u64, starttime_str, 10)
            catch return error.FailedToGetProcessStarttime;
        return starttime;
    }

    pub fn get_children(
        self: *const Self, children: *std.ArrayList(Self), pid: Pid
    ) Errors!void {
        const children_path = std.fmt.allocPrint(
            util.gpa, "/proc/{d}/task/{d}/children", .{ pid, pid }
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer util.gpa.free(children_path);
        const children_file = std.fs.openFileAbsolute(children_path, .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer children_file.close();
 
        var buf_reader = std.io.bufferedReader(children_file.reader());
        var reader = buf_reader.reader();
        var buf: [Lengths.SMALL]u8 = std.mem.zeroes([Lengths.SMALL]u8);
        var buf_fbs = std.io.fixedBufferStream(&buf);
        while (
            true
        ) {
            reader.streamUntilDelimiter(buf_fbs.writer(), ' ', buf_fbs.buffer.len)
                catch |err| switch (err) {
                    error.NoSpaceLeft => break,
                    error.EndOfStream => break,
                    else => |inner_err| return e.verbose_error(
                        inner_err, error.FailedToGetProcessChildren
                    )
                };
            const it = buf_fbs.getWritten();
            defer buf_fbs.reset();
            if (it.len == 0) {
                break;
            }

            const section = util.gpa.dupe(u8, it)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            defer util.gpa.free(section);
            const child_pid = std.fmt.parseInt(Pid, section, 10)
                catch return error.FailedToGetProcessChildren;

            var already_has_pid = false;
            for (children.items) |child| {
                if (child_pid == child.pid) {
                    already_has_pid = true;
                }
            }
            if (already_has_pid) {
                continue;
            }

            children.append(try Self.init(self.task, child_pid, null))
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            try self.get_children(children, child_pid);
        }
    }

    pub fn kill(self: *Self) Errors!void {
        if (libc.kill(self.pid, 9) != 0) {
            return error.FailedToKillProcess;
        }
    }

    /// Can either be set to sleep or active, if sleep then it sends a SIGSTOP
    /// signal to every process, if active then a SIGCONT is sent
    pub fn set_all_status(
        self: *Self,
        status: CpuStatus
    ) Errors!void {
        var children = std.ArrayList(Self).init(util.gpa);
        defer children.deinit();
        try self.get_children(&children, self.pid);
        children.append(self.*)
            catch |err| return e.verbose_error(err, error.FailedToSetProcessStatus);
        const sig = if (status == .Sleep) libc.SIGSTOP else libc.SIGCONT;
        for (children.items) |child| {
            if (libc.kill(child.pid, sig) != 0) {
                return error.FailedToSetProcessStatus;
            }
        }
    }

    pub fn limit_memory(self: *Self, limit: usize) Errors!void {
        self.memory_limit = limit;
        const rlimit = libc.rlimit {
            .rlim_cur = limit,
            .rlim_max = limit
        };
        const null_ptr: ?*libc.rlimit = null;
        var children = std.ArrayList(Self).init(util.gpa);
        defer children.deinit();
        children.append(self.*)
            catch |err| return e.verbose_error(err, error.FailedToGetProcess);
        try self.get_children(&children, self.pid);

        for (children.items) |child| {
            _ = libc.syscall(
                libc.SYS_prlimit64,
                child.pid,
                libc.RLIMIT_AS,
                &rlimit,
                &null_ptr
            );
        }
    }

};
