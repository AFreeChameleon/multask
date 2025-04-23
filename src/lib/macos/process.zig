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

const CpuStatus = @import("../task/process.zig").CpuStatus;

pub const MacosProcess = struct {
    const Self = @This();

    keep_running: bool = false,
    start_time: u64,
    pid: Pid,
    cpu: MacosCpu,
    children: []Self,
    task: *Task,
    file_strings: FileStrings,
    memory_limit: util.MemLimit = 0,

    pub fn init(
        pid: Pid,
        task: *Task,
    ) Errors!Self {
        const cpu = MacosCpu.init();
        const file_strings = FileStrings{
            .processes = std.mem.zeroes([1024]u8),
            .usage = std.mem.zeroes([1024]u8),
        };
        var proc = Self {
            .cpu = cpu,
            .pid = pid,
            .children = &.{},
            .task = task,
            .file_strings = file_strings,
            .start_time = 0
        };
        if (proc.proc_exists()) {
            proc.start_time = try proc.get_starttime();
        }

        return proc;
    }

    pub fn deinit(self: *Self) void {
        self.cpu.deinit();
    }

    pub fn monitor_stats(
        self: *Self,
    ) Errors!void {
        try self.task.files.clear_file("processes");
        try self.task.files.clear_file("usage");
        self.keep_running = false;
        const tree = try self.get_all_processes();

        try tree.build_file_strings(self);
        try self.save_files();

        if (!self.keep_running) {
            try self.kill_all();
        }
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

    pub fn get_starttime(self: *Self) Errors!u64 {
        const bsdinfo = try self.get_process_stats();
        return bsdinfo.pbi_start_tvsec;
    }

    fn build_file_strings(
        self: *Self,
        original: *Self,
    ) Errors!void {
        var proc_string = std.ArrayList(u8).init(util.gpa);
        defer proc_string.deinit();
        if (original.file_strings.processes[0] != 0) {
            proc_string.appendSlice(std.mem.sliceTo(&original.file_strings.processes, 0))
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }

        if (self.proc_exists()) {
            // Saving processes file
            const start_time = try self.get_starttime();
            const pid_str: []u8 = std.fmt.allocPrint(util.gpa, "{d}:{d},", .{
                self.pid, start_time
            }) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);
            defer util.gpa.free(pid_str);
            proc_string.appendSlice(try util.strdup(pid_str, error.FailedToSaveProcesses))
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);

            original.keep_running = true;

            // Saving cpu usage
            const cpu_usage = try self.cpu.get_cpu_usage();

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
        const taskinfo = try self.get_task_stats();
        self.cpu.old_stime = self.cpu.stime;
        self.cpu.old_utime = self.cpu.utime;
        self.cpu.stime = taskinfo.pti_total_system;
        self.cpu.utime = taskinfo.pti_total_user;
        try self.get_process_children(self.pid);
        return self;
    }

    fn check_memory_limit_within_limit(self: *Self) Errors!void {
        if (self.memory_limit != 0) {
            const mem = try self.get_memory();
            if (mem > self.memory_limit) {
                try self.kill();
            }
        }
    }

    fn get_process_children(
        self: *Self,
        ppid: Pid,
    ) Errors!void {
        var children = std.ArrayList(MacosProcess).init(util.gpa);
        defer children.deinit();
        const num_procs: Pid = libc.proc_listallpids(null, 0);
        const processes = util.gpa.alloc(Pid, @intCast(num_procs))
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);

        _ = libc.proc_listallpids(
            processes.ptr,
            @sizeOf(Pid) * num_procs
        );

        for (processes) |pid| {
            if (pid == 0) continue;
            var proc = try MacosProcess.init(pid, self.task);
            const bsdinfo = proc.get_process_stats()
                catch |err| switch (err) {
                    error.ProcessNotExists => continue,
                    else => return err
                };
            if (bsdinfo.pbi_ppid == ppid) {
                try self.check_memory_limit_within_limit();
                const taskinfo = try proc.get_task_stats();
                proc.cpu.stime = taskinfo.pti_total_system;
                proc.cpu.utime = taskinfo.pti_total_user;

                const old_time = Cpu.usage_stats.fetchPut(pid, .{ proc.cpu.utime, proc.cpu.stime })
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                if (old_time == null) {
                    proc.cpu.old_utime = 0;
                    proc.cpu.old_stime = 0;
                } else {
                    proc.cpu.old_utime = old_time.?.value[0];
                    proc.cpu.old_stime = old_time.?.value[1];
                }

                try proc.get_process_children(proc.pid);
                children.append(proc)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
            }
        }
        self.children = children.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
    }

    fn get_child_pids(
        self: *const Self,
        pids: *std.ArrayList(Pid),
        ppid: Pid,
        all_pids: ?[]Pid
    ) Errors!void {
        var processes: []Pid = undefined;
        if (all_pids == null) {
            const num_procs: Pid = libc.proc_listallpids(null, 0);
            processes = util.gpa.alloc(Pid, @intCast(num_procs))
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);

            _ = libc.proc_listallpids(
                processes.ptr,
                @sizeOf(Pid) * num_procs
            );
        } else {
            processes = all_pids.?;
        }
        for (processes) |pid| {
            if (pid == 0) continue;
            var proc = try MacosProcess.init(pid, self.task);
            const bsdinfo = proc.get_process_stats()
                catch |err| switch (err) {
                    error.ProcessNotExists => continue,
                    else => return err
                };
            if (bsdinfo.pbi_ppid == ppid) {
                pids.append(pid)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                try self.get_child_pids(pids, pid, processes);
            }
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

    pub fn kill_all(self: *const Self) Errors!void {
        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();
        if (libc.kill(self.pid, 9) != 0) {
            return error.FailedToKillAllProcesses;
        }
        try self.get_child_pids(&pids, self.pid, null);
        for (pids.items) |pid| {
            if (libc.kill(pid, 9) != 0) {
                return error.FailedToKillAllProcesses;
            }
        }
    }

    pub fn kill(self: *const Self) Errors!void {
        if (libc.kill(self.pid, 9) != 0) {
            return error.FailedToKillAllProcesses;
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
        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();
        try self.get_child_pids(&pids, self.pid, null);
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
};
