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

const CpuStatus = @import("../task/process.zig").CpuStatus;

pub const LinuxProcess = struct {
    const Self = @This();

    keep_running: bool = false,
    pid: Pid,
    cpu: LinuxCpu,
    children: []Self,
    task: *Task,
    file_strings: FileStrings,
    start_time: u32,
    memory_limit: util.MemLimit = 0,

    pub fn init(
        pid: Pid,
        task: *Task,
    ) Errors!Self {
        const cpu = LinuxCpu.init();
        const file_strings = FileStrings{
            .processes = std.mem.zeroes([Lengths.LARGE]u8),
            .usage = std.mem.zeroes([Lengths.LARGE]u8),
        };

        const proc = Self {
            .cpu = cpu,
            .pid = pid,
            .children = &.{},
            .task = task,
            .file_strings = file_strings,
            .start_time = 0
        };
        return proc;
    }

    pub fn monitor_stats(
        self: *Self,
    ) Errors!void {
        try self.task.files.clear_file("usage");
        try self.task.files.clear_file("processes");
        self.keep_running = false;
        var tree = try self.get_all_processes();

        try tree.build_file_strings(self);
        try self.save_files();

        if (!self.keep_running) {
            try self.kill_all();
        }

        // Setting it here so it's old on the next iteration
        self.cpu.time_total = self.cpu.get_cpu_time_total(
            try self.cpu.get_cpu_stats());
    }

    fn save_files(self: *Self) Errors!void {
        const usage = try self.task.files.get_file("usage");
        defer usage.close();
        const processes = try self.task.files.get_file("processes");
        defer processes.close();
        usage.writeAll(
            std.mem.trimRight(u8, &self.file_strings.usage, &[1]u8{0})
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        processes.writeAll(
            std.mem.trimRight(u8, &self.file_strings.processes, &[1]u8{0})
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        self.file_strings.processes = std.mem.zeroes([Lengths.LARGE]u8);
        self.file_strings.usage = std.mem.zeroes([Lengths.LARGE]u8);
    }

    fn build_file_strings(
        self: *Self,
        original: *Self,
    ) Errors!void {
        var proc_string = std.ArrayList(u8).init(util.gpa);
        if (original.file_strings.processes[0] != 0) {
            proc_string.appendSlice(std.mem.sliceTo(&original.file_strings.processes, 0))
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }

        if (self.proc_exists()) {
            // Saving processes file
            const start_time = try self.get_starttime();
            var pmap_buf: [Lengths.TINY]u8 = undefined;
            const pid_str: []u8 = std.fmt.bufPrint(&pmap_buf, "{d}:{d},", .{
                self.pid, start_time
            }) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);
            proc_string.appendSlice(try util.strdup(pid_str, error.FailedToSaveProcesses))
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);

            original.keep_running = true;

            // Saving cpu usage
            const cpu_usage = try self.cpu.get_cpu_usage(original.cpu.time_total);

            var precise_cpu_buf: [Lengths.SMALL]u8 = undefined;
            const precise_cpu_usage = std.fmt.formatFloat(
                &precise_cpu_buf,
                cpu_usage,
                .{ .precision = 2, .mode = .decimal }
            ) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);

            var usage_buf: [Lengths.LARGE]u8 = undefined;
            const usage = std.fmt.bufPrint(
                &usage_buf,
                "{s}{d}:{s}|",
                .{
                    std.mem.sliceTo(&original.file_strings.usage, 0),
                    self.pid,
                    precise_cpu_usage
                }
            ) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);
            std.mem.copyForwards(u8, &original.file_strings.usage, usage);
            if (self.children.len == 0) {
                std.mem.copyForwards(u8, &original.file_strings.processes, proc_string.items);
            }
        }
        if (self.children.len == 0) {
            return;
        }

        proc_string.appendSlice("(")
            catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);
        std.mem.copyForwards(u8, &original.file_strings.processes, proc_string.items);

        for (self.children) |*child| {
            try child.build_file_strings(original);
        }

        var processes_buf: [Lengths.LARGE]u8 = undefined;
        const processes = std.fmt.bufPrint(&processes_buf, "{s})", .{
            std.mem.sliceTo(&original.file_strings.processes, 0),
        }) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);

        std.mem.copyForwards(u8, &original.file_strings.processes, processes);
    }

    pub fn get_all_processes(self: *Self) Errors!*Self {
        if (!self.proc_exists()) {
            return self;
        }
        try self.check_memory_limit_within_limit();
        const p_stats = try self.get_process_stats();
        var utime: u64 = 0;
        var stime: u64 = 0;
        if (p_stats.len > 0) {
            utime = std.fmt.parseInt(u64, p_stats[13], 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
            stime = std.fmt.parseInt(u64, p_stats[14], 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }
        const old_time = Cpu.usage_stats.fetchPut(self.pid, .{ utime, stime })
            catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        if (old_time == null) {
            self.cpu.old_utime = 0;
            self.cpu.old_stime = 0;
        } else {
            self.cpu.old_utime = old_time.?.value[0];
            self.cpu.old_stime = old_time.?.value[1];
        }
        self.cpu.utime = utime;
        self.cpu.stime = stime;
        try self.get_process_children(self.pid);
        return self;
    }

    fn get_process_children(
        self: *Self,
        pid: Pid,
    ) Errors!void {
        var children = std.ArrayList(LinuxProcess).init(util.gpa);
        defer children.deinit();

        var buf: [Lengths.LARGE]u8 = undefined;
        const children_path = std.fmt.bufPrint(&buf, "/proc/{d}/task/{d}/children", .{ pid, pid })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        const children_file = std.fs.openFileAbsolute(children_path, .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer children_file.close();

        buf = std.mem.zeroes([Lengths.LARGE]u8);
        var children_file_reader = std.io.bufferedReader(children_file.reader());
        var in_stream = children_file_reader.reader();
        while (
            in_stream.readUntilDelimiterOrEof(&buf, ' ')
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren)
        ) |it| {
            const section = util.gpa.dupe(u8, it)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            const child_pid = std.fmt.parseInt(Pid, section, 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            var new_process = try LinuxProcess.init(child_pid, self.task);
            const child_stats = try new_process.get_process_stats();
            const utime = std.fmt.parseInt(u64, child_stats[13], 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            const stime = std.fmt.parseInt(u64, child_stats[14], 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);

            const old_time = Cpu.usage_stats.fetchPut(child_pid, .{ utime, stime })
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            if (old_time == null) {
                new_process.cpu.old_utime = 0;
                new_process.cpu.old_stime = 0;
            } else {
                new_process.cpu.old_utime = old_time.?.value[0];
                new_process.cpu.old_stime = old_time.?.value[1];
            }
            new_process.cpu.utime = utime;
            new_process.cpu.stime = stime;

            try new_process.get_process_children(new_process.pid);
            children.append(new_process)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        }

        self.children = children.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
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
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer stat_file.close();

        var buf: [Lengths.LARGE]u8 = std.mem.zeroes([Lengths.LARGE]u8);
        var stat_file_reader = std.io.bufferedReader(stat_file.reader());
        var in_stream = stat_file_reader.reader();

        var bracket_count: i32 = 0;
        while (in_stream.readUntilDelimiterOrEof(&buf, ' ')
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats)) |stat| {
            const section: []u8 = util.gpa.dupe(u8, stat)
                catch |err| return e.verbose_error(err, error.FailedToGetProcess);
            if (section[0] == '(') {
                bracket_count += 1;
            }
            if (section[section.len - 1] == ')') {
                bracket_count -= 1;
                if (bracket_count == 0) {
                    stat_line.appendSlice(section)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcess);
                }
            }
            if (bracket_count > 0) {
                stat_line.appendSlice(section)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcess);
            }

            if (bracket_count == 0) {
                stats.append(if (stat_line.capacity == 0)
                    section
                else
                    stat_line.toOwnedSlice()
                    catch |err| return e.verbose_error(err, error.FailedToGetProcess)) catch |err| return e.verbose_error(err, error.FailedToGetProcess);

                stat_line.clearAndFree();
            }
        }

        return stats.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcess);
    }

    /// Checks if process exists by checking the pid exists, and if it's a zombie process
    /// also checks if process has the same start time (for new processes with same pid)
    pub fn proc_exists(self: *Self) bool {
        if (self.pid == 0) return false;
        const state = self.get_process_state()
            catch return false;
        if (state != null) {
            return state.? != 'Z';
        }
        const starttime = self.get_starttime()
            catch return false;
        if (starttime != self.start_time) {
            return false;
        }
        return libc.kill(self.pid, 0) == 0;
    }

    fn get_process_state(self: *Self) Errors!?u8 {
        const pid_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/status", .{self.pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessState);
        defer util.gpa.free(pid_path);
        const status_file = std.fs.openFileAbsolute(pid_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
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

    pub fn get_starttime(self: *Self) Errors!u32 {
        const stats = try self.get_process_stats();
        const starttime_str = stats[21];
        const starttime: u32 = std.fmt.parseInt(u32, starttime_str, 10)
            catch return error.FailedToGetProcessStarttime;
        return starttime;
    }

    fn get_child_pids(
        self: *const Self, pids: *std.ArrayList(Pid), pid: Pid
    ) Errors!void {
        var file_buf: [Lengths.SMALL]u8 = undefined;
        const children_path = std.fmt.bufPrint(
            &file_buf, "/proc/{d}/task/{d}/children", .{ pid, pid }
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
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
            const child_pid = std.fmt.parseInt(Pid, section, 10)
                catch return error.FailedToGetProcessChildren;
            if (util.count_occurrences(Pid, &pids.items, child_pid) > 0) {
                continue;
            }

            pids.append(child_pid)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            try self.get_child_pids(pids, child_pid);
        }
    }

    pub fn kill(self: *Self) Errors!void {
        if (libc.kill(self.pid, 9) != 0) {
            return error.FailedToKillProcess;
        }
    }

    pub fn kill_all(self: *Self) Errors!void {
        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();
        var res = libc.kill(self.pid, 9);
        if (res != 0) {
            return error.FailedToKillAllProcesses;
        }
        try self.get_child_pids(&pids, self.pid);
        for (pids.items) |pid| {
            res = libc.kill(pid, 9);
            if (res != 0) {
                return error.FailedToKillAllProcesses;
            }
        }
    }

    /// Can either be set to sleep or active, if sleep then it sends a SIGSTOP
    /// signal to every process, if active then a SIGCONT is sent
    pub fn set_all_status(
        self: *Self,
        status: CpuStatus
    ) Errors!void {
        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();
        try self.get_child_pids(&pids, self.pid);
        pids.append(self.pid)
            catch |err| return e.verbose_error(err, error.FailedToSetProcessStatus);
        const sig = if (status == .Sleep) libc.SIGSTOP else libc.SIGCONT;
        const pids_owned = pids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToSetProcessStatus);
        for (pids_owned) |pid| {
            if (libc.kill(pid, sig) != 0) {
                return error.FailedToSetProcessStatus;
            }
        }
    }

    fn check_memory_limit_within_limit(self: *Self) Errors!void {
        if (self.memory_limit != 0) {
            const mem = try self.get_memory();
            if (mem > self.memory_limit) {
                try self.kill();
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
        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();
        pids.append(self.pid)
            catch |err| return e.verbose_error(err, error.FailedToGetProcess);
        try self.get_child_pids(&pids, self.pid);

        for (pids.items) |pid| {
            _ = libc.syscall(
                libc.SYS_prlimit64,
                pid,
                libc.RLIMIT_AS,
                &rlimit,
                &null_ptr
            );
        }
    }
};
