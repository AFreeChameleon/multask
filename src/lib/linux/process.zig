const std = @import("std");
const libc = @import("../c.zig").libc;
const log = @import("../log.zig");
const util = @import("../util.zig");
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const Lengths = util.Lengths;
const FileStrings = util.FileStrings;
const e = @import("../error.zig");
const Errors = e.Errors;
const Find = @import("../file.zig").Find;

const ProcFs = @import("./file.zig").ProcFs;

const t = @import("../task/index.zig");
const TaskFiles = t.Files;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const Cpu = @import("./cpu.zig");
const LinuxCpu = Cpu.LinuxCpu;

const taskproc = @import("../task/process.zig");
const CpuStatus = taskproc.CpuStatus;
const Monitoring = taskproc.Monitoring;

const r = @import("../task/resources.zig");
const Resources = r.Resources;
const JSON_Resources = r.JSON_Resources;

const f = @import("../task/file.zig");
const ReadProcess = f.ReadProcess;


pub const LinuxProcess = struct {
    const Self = @This();

    // When these are set to null, it means to fetch them because they're not saved yet
    pub const InitArgs = struct {
        sid: Sid,
        pgrp: Pgrp,
        starttime: u64
    };

    /// Can either be ReadProcess or TaskReadProcess
    pub fn get_init_args_from_readproc(comptime T: type, proc: T) InitArgs {
        return InitArgs {
            .sid = proc.sid,
            .pgrp = proc.pgrp,
            .starttime = proc.starttime,
        };
    }

    var LoadAvgPid: Pid = 0;

    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
    task: *Task,
    children: ?[]Self = null,
    memory_limit: util.MemLimit = 0,

    /// Only set start time to anything from a saved json file
    pub fn init(
        task: *Task,
        pid: Pid,
        data: ?InitArgs,
    ) Errors!Self {
        var proc = Self {
            .pid = pid,
            .task = task,
            .starttime = 0,
            .sid = 0,
            .pgrp = 0,
        };
        const procExists = proc.proc_exists();
        if (procExists) {
            const stats = try ProcFs.get_process_stats(proc.pid);
            defer stats.deinit();

            if (data != null) {
                proc.starttime = data.?.starttime;
                proc.pgrp = data.?.pgrp;
                proc.sid = data.?.sid;
            } else {
                proc.starttime = try get_starttime(stats);
                proc.pgrp = try get_pgrp(stats);
                proc.sid = try get_sid(stats);
            }
        } else {
            if (data != null) {
                proc.starttime = data.?.starttime;
                proc.pgrp = data.?.pgrp;
                proc.sid = data.?.sid;
            }
        }
        return proc;
    }

    pub fn deinit(self: Self) void {
        if (self.children != null) {
            util.gpa.free(self.children.?);
        }
    }

    pub fn monitor_stats(
        self: *Self
    ) Errors!void {
        var keep_running = false;

        const loadavg_pid: Pid = try get_most_recent_pid();
        if (loadavg_pid != LoadAvgPid) {
            LoadAvgPid = loadavg_pid;
            const related_procs = try self.get_related_procs();

            // If a new process has been created, do this search
            if (self.proc_exists() or related_procs.len > 0) {
                keep_running = true;
                if (self.children != null and self.children.?.len > 0) {
                    util.gpa.free(self.children.?);
                }
                self.children = related_procs;
            } else {
                util.gpa.free(related_procs);
            }
        } else if (self.proc_exists() or self.proc_children_exists()) {
            keep_running = true;
        }

        try taskproc.check_memory_limit_within_limit(self);

        try taskproc.save_files(self);
        try LinuxCpu.update_time_total();
        if (!keep_running) {
            try taskproc.kill_all(self);
        }
    }

    pub fn get_related_procs(
        self: *Self
    ) Errors![]LinuxProcess {
        // If main proc doesnt exist, read the saved child processes
        // if any of those exist, set the main process to the first one that's running?
        // should I do that? what if there are multiple child processes running alongside each other?
        // don't do it because I can just check saved processes and add it
        // to the children array and save them
        var related_procs = std.ArrayList(Self).init(util.gpa);
        defer related_procs.deinit();
        if (self.proc_exists()) {
            try self.get_children(&related_procs, self.pid);
        } else {
            const saved_procs = try taskproc.get_running_saved_procs(self);
            defer util.gpa.free(saved_procs);
            for (saved_procs) |sproc| {
                var exists = false;
                for (related_procs.items) |proc| {
                    if (
                        sproc.pid == proc.pid and
                        sproc.starttime == proc.starttime
                    ) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    const args = InitArgs {
                        .sid = sproc.sid,
                        .pgrp = sproc.pgrp,
                        .starttime = sproc.starttime
                    };
                    related_procs.append(
                        try Self.init(sproc.task, sproc.pid, args)
                    ) catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                    try self.get_children(&related_procs, sproc.pid);
                }
            }
        }

        if (self.task.daemon == null) {
            return error.FailedToGetRelatedProcs;
        }

        if (self.task.stats.monitoring == Monitoring.Deep) {
            related_procs.append(self.*)
                catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
            related_procs.append(self.task.daemon.?)
                catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
            const procs = try self.search_related_procs(related_procs.items);
            related_procs.appendSlice(procs)
                catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
        }

        const unique_procs = try taskproc.filter_dupe_and_self_procs(self, related_procs.items);

        return unique_procs;
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
        const content = try ProcFs.read_file(self.pid, ProcFs.FileType.Comm);
        return std.mem.trimRight(u8, content, &[2]u8{0, '\n'});
    }


    pub fn proc_children_exists(self: *Self) bool {
        if (self.children == null or self.children.?.len == 0) {
            return false;
        }
        for (self.children.?) |*proc| {
            if (proc.proc_exists()) {
                return true;
            }
        }
        return false;
    }

    /// Checks if process exists by checking the pid exists, and if it's a zombie process
    /// also checks if process has the same start time (for new processes with same pid)
    pub fn proc_exists(self: *Self) bool {
        if (self.pid == 0) return false;
        if (libc.kill(self.pid, 0) != 0) {
            return false;
        }
        // Can't check start time because it hasn't been set
        if (self.starttime != 0) {
            const stats = ProcFs.get_process_stats(self.pid)
                catch return false;
            defer stats.deinit();
            const starttime = get_starttime(stats)
                catch return false;
            if (starttime != self.starttime) {
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
        const stats = try ProcFs.get_process_stats(self.pid);
        defer stats.deinit();

        const state = stats.val[2][0]; // State is only one character
        return state;
    }

    pub fn get_memory(self: *Self) Errors!u64 {
        const statm = try ProcFs.read_file(self.pid, ProcFs.FileType.Statm);
        defer util.gpa.free(statm);

        var itr = std.mem.splitAny(u8, statm, " ");
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

        const stats = try ProcFs.get_process_stats(self.pid);
        defer stats.deinit();
        const starttime = std.fmt.parseInt(u64, stats.val[21], 10)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);

        const uptime = try ProcFs.read_file(null, ProcFs.FileType.RootUptime);
        defer util.gpa.free(uptime);

        var split_str = std.mem.splitSequence(u8, uptime, " ");
        const secs_since_boot_str = split_str.next();
        if (secs_since_boot_str == null) {
            return error.FailedToGetProcessRuntime;
        }

        const secs_since_boot = std.fmt.parseInt(
            u64, secs_since_boot_str.?[0..secs_since_boot_str.?.len - 3], 10
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);

        const ticks_per_sec: u64 = @intCast(libc.sysconf(libc._SC_CLK_TCK));

        if (secs_since_epoch -
            (secs_since_boot - @divTrunc(starttime, ticks_per_sec)) < 0
        ) {
            return error.FailedToGetProcessRuntime;
        }
        const runtime: u64 = secs_since_epoch -
            (secs_since_boot - @divTrunc(starttime, ticks_per_sec));

        return secs_since_epoch - runtime;
    }

    pub fn get_starttime(stats: ProcFs.Stats) Errors!u64 {
        const starttime_str = stats.val[21];
        const starttime: u64 = std.fmt.parseInt(u64, starttime_str, 10)
            catch return error.FailedToGetProcessStarttime;
        return starttime;
    }

    pub fn get_sid(stats: ProcFs.Stats) Errors!Pid {
        const sid_str = stats.val[5];
        const sid: Pid = std.fmt.parseInt(Pid, sid_str, 10)
            catch return error.FailedToGetProcessStarttime;
        return sid;
    }

    pub fn get_pgrp(stats: ProcFs.Stats) Errors!Pid {
        const pgrp_str = stats.val[4];
        const pgrp: Pid = std.fmt.parseInt(Pid, pgrp_str, 10)
            catch return error.FailedToGetProcessStarttime;
        return pgrp;
    }

    pub fn get_most_recent_pid() Errors!Pid {
        const loadavg = try ProcFs.get_loadavg();
        defer loadavg.deinit();
        const pid = std.fmt.parseInt(Pid, loadavg.val[4], 10)
            catch return error.FailedToGetLoadavg;
        try log.printdebug("Most recent pid: {d}", .{pid});
        return pid;
    }

    pub fn get_children(
        self: *const Self, children: *std.ArrayList(Self), pid: Pid
    ) Errors!void {
        const child_pids = try ProcFs.get_proc_children(pid);
        defer util.gpa.free(child_pids);
        for (child_pids) |cpid| {
            var already_has_pid = false;
            for (children.items) |child| {
                if (cpid == child.pid) {
                    already_has_pid = true;
                }
            }
            if (already_has_pid) {
                continue;
            }

            children.append(try Self.init(self.task, cpid, null))
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            try self.get_children(children, cpid);
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

    /// Get all processes in the same pgrp or sid or is a child of ppid
    pub fn search_related_procs(
        self: *Self,
        procs: []LinuxProcess
    ) Errors![]LinuxProcess {
        var proc_dir = try ProcFs.get_procs_dir();
        defer proc_dir.close();
        var proc_dir_itr = proc_dir.iterate();

        var related_procs = std.ArrayList(Self).init(util.gpa);
        defer related_procs.deinit();

        while (
            proc_dir_itr.next()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren)
        ) |entry| {
            if (entry.kind != .directory) {
                continue;
            }

            const pid = std.fmt.parseInt(util.Pid, entry.name, 10)
                catch continue;

            // Stops any parent shell process or the daemon itself
            if (pid < self.task.daemon.?.pid or pid == self.task.daemon.?.pid) {
                continue;
            }

            var exists = false;
            for (procs) |p| {
                if (p.pid == pid) {
                    exists = true;
                    break;
                }
            }
            if (exists) continue;

            const stats = ProcFs.get_process_stats(pid)
                catch continue;
            defer stats.deinit();

            const proc_ppid = std.fmt.parseInt(Pid, stats.val[3], 10)
                catch return error.FailedToGetProcessStats;
            const proc_pgrp = std.fmt.parseInt(Pid, stats.val[4], 10)
                catch return error.FailedToGetProcessStats;
            const proc_sid = std.fmt.parseInt(Pid, stats.val[5], 10)
                catch return error.FailedToGetProcessStats;

            if (ProcFs.proc_has_taskid_in_env(pid, self.task.id)) {
                const new_proc = try Self.init(self.task, pid, .{
                    .sid = proc_sid,
                    .pgrp = proc_pgrp,
                    .starttime = try get_starttime(stats)
                });
                related_procs.append(new_proc)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);

                continue;
            }

            for (procs) |proc| {
                if (
                    proc_ppid == proc.pid or
                    proc_sid == proc.sid or
                    proc_pgrp == proc.pgrp
                ) {
                    const new_proc = try Self.init(self.task, pid, .{
                        .sid = proc_sid,
                        .pgrp = proc_pgrp,
                        .starttime = try get_starttime(stats)
                    });
                    related_procs.append(new_proc)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                    break;
                }
            }
        }

        return related_procs.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
    }

};
