const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const Lengths = util.Lengths;
const Pid = util.Pid;
const FileStrings = util.FileStrings;
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

pub const MacosProcess = struct {
    const Self = @This();

    pid: Pid,
    task: *Task,
    start_time: u64,
    children: ?[]Self = null,
    memory_limit: util.MemLimit = 0,

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

        try MacosCpu.update_time_total(self);
        if (!keep_running) {
            try taskproc.kill_all(self);
        }
    }

    pub fn get_starttime(self: *Self) Errors!u64 {
        const bsdinfo = try self.get_process_stats();
        return bsdinfo.pbi_start_tvsec;
    }

    var all_pids: ?[]Pid = null;
    var parent_pid: ?Pid = null;
    pub fn get_children(
        self: *const Self, children: *std.ArrayList(Self), ppid: Pid
    ) Errors!void {
        // if this is the first process
        if (all_pids == null) {
            parent_pid = ppid;
            const num_procs: Pid = libc.proc_listallpids(null, 0);
            all_pids = util.gpa.alloc(Pid, @intCast(num_procs))
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);

            _ = libc.proc_listallpids(
                all_pids.?.ptr,
                @sizeOf(Pid) * num_procs
            );
        }
        for (all_pids.?) |pid| {
            if (pid == 0) continue;
            var proc = try MacosProcess.init(self.task, pid, null);
            const bsdinfo = proc.get_process_stats()
                catch |err| switch (err) {
                    error.ProcessNotExists => continue,
                    else => return err
                };
            if (bsdinfo.pbi_ppid == ppid) {
                children.append(try Self.init(self.task, pid, bsdinfo.pbi_start_tvsec))
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                try self.get_children(children, pid);
            }
        }
        // if this is the first process
        if (parent_pid == ppid) {
            util.gpa.free(all_pids.?);
            all_pids = null;
            parent_pid = null;
        }
    }

    pub fn get_all_process_stats(self: *const Self) Errors!libc.proc_taskallinfo {
        var info: libc.proc_taskallinfo = std.mem.zeroes(libc.proc_taskallinfo);
        const res = libc.proc_pidinfo(
            self.pid, libc.PROC_PIDTASKALLINFO, 0, &info, @sizeOf(libc.proc_taskallinfo)
        );
        if (res != @sizeOf(libc.proc_taskallinfo) or info.pbsd.pbi_status == libc.SZOMB) {
            // These logs are disabled because there's a whole lot of them
            // try log.printdebug("get_all_process_stats: Macos LIBC error {d}", .{libc.__error().*});
            return error.ProcessNotExists;
        } else {
            return info;
        }
    }

    pub fn get_process_stats(self: *const Self) Errors!libc.proc_bsdinfo {
        var info: libc.proc_bsdinfo = std.mem.zeroes(libc.proc_bsdinfo);
        const res = libc.proc_pidinfo(
            self.pid, libc.PROC_PIDTBSDINFO, 0, &info, @sizeOf(libc.proc_bsdinfo)
        );
        if (res != @sizeOf(libc.proc_bsdinfo) or info.pbi_status == libc.SZOMB) {
            // try log.printdebug("get_process_stats: Macos LIBC error {d}", .{libc.__error().*});
            return error.ProcessNotExists;
        } else {
            return info;
        }
    }

    pub fn get_task_stats(self: *const Self) Errors!libc.proc_taskinfo {
        var info: libc.proc_taskinfo = std.mem.zeroes(libc.proc_taskinfo);
        const res = libc.proc_pidinfo(
            self.pid, libc.PROC_PIDTASKINFO, 0, &info, @sizeOf(libc.proc_taskinfo)
        );
        if (res != @sizeOf(libc.proc_taskinfo)) {
            // try log.printdebug("get_task_stats: Macos LIBC error {d}", .{libc.__error().*});
            return error.ProcessNotExists;
        } else {
            return info;
        }
    }

    pub fn get_exe(self: *const Self) Errors![]const u8 {
        const bsdinfo = try self.get_process_stats();
        return try util.strdup(&bsdinfo.pbi_comm, error.FailedToGetProcessComm);
    }

    pub fn get_memory(self: *const Self) Errors!u64 {
        const taskinfo = try self.get_task_stats();
        return taskinfo.pti_resident_size;
    }

    pub fn get_runtime(self: *const Self) Errors!u64 {
        const bsdinfo = try self.get_process_stats();
        const since_epoch = @as(u64, @intCast(std.time.milliTimestamp())) / std.time.ms_per_s;
        if (since_epoch < 0) {
            return error.FailedToGetProcessRuntime;
        }
        return since_epoch - bsdinfo.pbi_start_tvsec;
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
        if (self.start_time != 0 and self.start_time != info.pbi_start_tvsec) {
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
        procs.append(try Self.init(self.task, self.pid, self.start_time))
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
