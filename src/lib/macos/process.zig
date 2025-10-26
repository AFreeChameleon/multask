const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const e = @import("../error.zig");
const Errors = e.Errors;
const Find = @import("../file.zig").Find;

const log = @import("../log.zig");

const t = @import("../task/index.zig");
const TaskFiles = t.Files;
const Task = t.Task;
const TaskId = t.TaskId;

const MainFiles = @import("../file.zig").MainFiles;
const Cpu = @import("./cpu.zig");
const MacosCpu = Cpu.MacosCpu;

const taskproc = @import("../task/process.zig");
const CpuStatus = taskproc.CpuStatus;

const f = @import("../task/file.zig");
const ReadProcess = f.ReadProcess;

const procstats = @import("./stats.zig");
const procenv = @import("./env.zig");

pub const MacosProcess = struct {
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

    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    task: *Task,
    starttime: u64,
    children: ?[]Self = null,
    memory_limit: util.MemLimit = 0,

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
            const bsdstats = try procstats.get_process_stats(pid);

            if (data != null) {
                proc.starttime = data.?.starttime;
                proc.pgrp = data.?.pgrp;
                proc.sid = data.?.sid;
            } else {
                proc.starttime = procstats.get_starttime(&bsdstats);
                proc.pgrp = procstats.get_pgrp(&bsdstats);
                proc.sid = try procstats.get_sid(pid);
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
        self: *Self,
    ) Errors!void {
        var keep_running = false;

        const related_procs = try self.get_related_procs();
        defer util.gpa.free(related_procs);
        defer self.children = null;
        if (self.proc_exists() or related_procs.len > 0) {
            keep_running = true;
            self.children = related_procs;
        }

        try taskproc.check_memory_limit_within_limit(self);

        try taskproc.save_files(self);
        if (self.task.daemon == null) {
            return error.ForkFailed;
        }
        try self.task.resources.?.meta.?.update_time_total(&self.task.daemon.?);
        if (!keep_running) {
            try taskproc.kill_all(self);
        }
    }

    pub fn get_related_procs(self: *Self) Errors![]Self {
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

        if (self.task.stats.?.monitoring == .Deep) {
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

    /// Get all processes in the same pgrp or sid or is a child of ppid
    pub fn search_related_procs(
        self: *Self,
        procs: []Self
    ) Errors![]Self {
        var related_procs = std.ArrayList(Self).init(util.gpa);
        defer related_procs.deinit();

        const num_procs = libc.proc_listallpids(null, 0);
        const all_procs = util.gpa.alloc(Pid, @intCast(num_procs))
            catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
        defer util.gpa.free(all_procs);

        _ = libc.proc_listallpids(
            all_procs.ptr,
            @sizeOf(Pid) * num_procs
        );
        
        for (all_procs) |pid| {
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

            const bsdinfo = procstats.get_process_stats(pid)
                catch |err| switch (err) {
                    error.ProcessNotExists => continue,
                    else => return err
                };
            const proc_pgrp = procstats.get_pgrp(&bsdinfo);
            const proc_ppid = try procstats.get_ppid(&bsdinfo);
            const proc_sid = try procstats.get_sid(pid);

            if (procenv.proc_has_taskid_in_env(pid, self.task.id) catch continue) {
                const starttime = procstats.get_starttime(&bsdinfo);
                const new_proc = try Self.init(self.task, pid, .{
                    .sid = proc_sid,
                    .pgrp = proc_pgrp,
                    .starttime = starttime
                });
                related_procs.append(new_proc)
                    catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
                continue;
            }

            for (procs) |proc| {
                if (
                    proc_ppid == proc.pid or
                    proc_sid == proc.sid or
                    proc_pgrp == proc.pgrp
                ) {
                    const starttime = procstats.get_starttime(&bsdinfo);
                    const new_proc = try Self.init(self.task, pid, .{
                        .sid = proc_sid,
                        .pgrp = proc_pgrp,
                        .starttime = starttime
                    });
                    related_procs.append(new_proc)
                        catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
                    break;
                }
            }
        }

        return related_procs.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetRelatedProcs);
    }

    var all_pids: ?[]Pid = null;
    var parent_pid: ?Pid = null;
    pub fn get_children(
        self: *const Self, children: *std.ArrayList(Self), ppid: Pid
    ) Errors!void {
        // if this is the first process
        if (all_pids == null) {
            parent_pid = ppid;
            const num_procs = libc.proc_listallpids(null, 0);
            all_pids = util.gpa.alloc(Pid, @intCast(num_procs))
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);

            _ = libc.proc_listallpids(
                all_pids.?.ptr,
                @sizeOf(Pid) * num_procs
            );
        }
        for (all_pids.?) |pid| {
            if (pid == 0) continue;
            const proc = try MacosProcess.init(self.task, pid, null);
            const bsdinfo = procstats.get_process_stats(proc.pid)
                catch |err| switch (err) {
                    error.ProcessNotExists => continue,
                    else => return err
                };
            const proc_ppid = try procstats.get_ppid(&bsdinfo);
            if (proc_ppid == ppid) {
                const sid = try procstats.get_sid(pid);
                const starttime = procstats.get_starttime(&bsdinfo);
                const pgrp = procstats.get_pgrp(&bsdinfo);
                const init_args = InitArgs {
                    .starttime = starttime,
                    .sid = sid,
                    .pgrp = pgrp
                };
                children.append(try Self.init(self.task, pid, init_args))
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                try self.get_children(children, pid);
            }
        }
        // if this is the first process which means the nesting has finished
        if (parent_pid == ppid) {
            util.gpa.free(all_pids.?);
            all_pids = null;
            parent_pid = null;
        }
    }

    pub fn get_exe(self: *Self) Errors![]const u8 {
        const stats = try procstats.get_process_stats(self.pid);
        const comm = procstats.get_exe(&stats);
        return try util.strdup(comm, error.FailedToGetProcessComm);
    }

    pub fn get_memory(self: *Self) Errors!u64 {
        const stats = try procstats.get_task_stats(self.pid);
        const mem = procstats.get_memory(&stats);
        return mem;
    }

    pub fn get_runtime(self: *Self) Errors!u64 {
        const stats = try procstats.get_process_stats(self.pid);
        const runtime = try procstats.get_runtime(&stats);
        return runtime;
    }

    pub fn proc_exists(self: *const Self) bool {
        // Do some checking here if it's not only the right pid but the same comm
        // Or has a parent pid of one of the processes
        var info: libc.proc_bsdinfo = std.mem.zeroes(libc.proc_bsdinfo);
        const res = libc.proc_pidinfo(
            self.pid, libc.PROC_PIDTBSDINFO, 0, &info, libc.PROC_PIDTBSDINFO_SIZE
        );
        if (
            res != @sizeOf(libc.proc_bsdinfo) or info.pbi_status == libc.SZOMB
        ) {
            return false;
        }
        if (self.starttime != 0 and self.starttime != info.pbi_start_tvsec) {
            return false;
        }
        return true;
    }

    pub fn kill(self: *const Self) Errors!void {
        if (libc.kill(self.pid, 9) != 0) {
            return error.FailedToKillProcess;
        }
    }

    pub fn limit_memory(self: *Self, limit: usize) Errors!void {
        // Macos can't set memory to process by pid so this logic is
        // done manually in the monitor_process function
        self.memory_limit = limit;
    }

    /// Can either be set to sleep or active, if sleep then it sends a SIGSTOP
    /// signal to every process, if active then a SIGCONT is sent
    pub fn set_all_status(
        self: *Self,
        status: CpuStatus
    ) Errors!void {
        var procs = std.ArrayList(Self).init(util.gpa);
        defer procs.deinit();
        try self.get_children(&procs, self.pid);

        const init_args = InitArgs {
            .starttime = self.starttime,
            .sid = self.sid,
            .pgrp = self.pgrp
        };
        procs.append(try Self.init(self.task, self.pid, init_args))
            catch |err| return e.verbose_error(err, error.FailedToSetProcessStatus);
        const sig = if (status == .Sleep) libc.SIGSTOP else libc.SIGCONT;
        const procs_owned = procs.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToSetProcessStatus);
        for (procs_owned) |proc| {
            if (libc.kill(proc.pid, sig) != 0) {
                return error.FailedToSetProcessStatus;
            }
        }
    }
};
