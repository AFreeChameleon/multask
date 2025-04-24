const libc = @import("../c.zig").libc;
const std = @import("std");
const util = @import("../util.zig");
const winutil = @import("./util.zig");
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

const log = @import("../log.zig");

const WindowsCpu = @import("./cpu.zig").WindowsCpu;

const Jobs = struct {
    header: libc.JOBOBJECT_BASIC_PROCESS_ID_LIST,
    list: [1024]util.Pid
};

pub const WindowsProcess = struct {
    const Self = @This();
    
    keep_running: bool = false,
    pid: Pid,
    cpu: WindowsCpu,
    children: []Self,
    task: *Task,
    file_strings: FileStrings,
    start_time: u64,
    job_handle: ?*anyopaque = null,

    pub fn init(
        pid: Pid,
        task: *Task,
    ) Errors!Self {
        const file_strings = FileStrings{
            .processes = std.mem.zeroes([1024]u8),
            .usage = std.mem.zeroes([1024]u8),
        };

        return Self {
            .pid = pid,
            .children = &.{},
            .task = task,
            .file_strings = file_strings,
            .start_time = 0,
            .cpu = WindowsCpu.init()
        };
    }

    pub fn proc_exists(self: *Self) bool {
        const proc_handle = libc.OpenProcess(libc.PROCESS_QUERY_INFORMATION, 1, self.pid);
        if (proc_handle == null) {
            return false;
        }
        var exit_code: u32 = 0;
        if (libc.GetExitCodeProcess(proc_handle, &exit_code) == 0) {
            return false;
        }
        if (exit_code != libc.STILL_ACTIVE) {
            return false;
        }
        return true;
    }

    pub fn monitor_stats(
        self: *Self,
    ) Errors!void {
        try self.task.files.clear_file("usage");
        try self.task.files.clear_file("processes");
        self.keep_running = false;
        const tree = try self.get_all_processes();

        try tree.build_file_strings(self);
        try self.save_files();

        if (!self.keep_running) {
            try self.kill_all();
        }

    }

    pub fn kill_all(self: *Self) Errors!void {
        const job_handle = try self.get_job_handle();
        if (libc.TerminateJobObject(job_handle, 1) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToKillAllProcesses;
        }
    }

    fn kill(self: *Self) Errors!void {
        if (!self.proc_exists()) {
            return error.ProcessNotExists;
        }

        var proc_name: [Lengths.LARGE]u8 = std.mem.zeroes([Lengths.LARGE]u8);
        const proc_handle = libc.OpenProcess(
            libc.PROCESS_TERMINATE | libc.PROCESS_QUERY_INFORMATION | libc.SYNCHRONIZE,
            1,
            self.pid
        );

        if (libc.GetProcessImageFileNameA(proc_handle, &proc_name, @intCast(proc_name.len)) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToKillAllProcesses;
        }

        const trimmed_name = std.mem.trim(u8, &proc_name, &[1]u8{0});
        if (std.mem.indexOf(u8, trimmed_name, "mspdbsrv") != null) {
            try log.printdebug("Cannot kill mspdbsrv", .{});
            return;
        }

        if (libc.TerminateProcess(proc_handle, 1) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToKillAllProcesses;
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

    fn get_stats(self: *const Self) Errors![3]u64 {
        const proc_handle = libc.OpenProcess(libc.PROCESS_ALL_ACCESS, 1, self.pid);
        defer _ = libc.CloseHandle(proc_handle);
        var lp_creation_time = std.mem.zeroes(libc.FILETIME);
        var lp_exit_time = std.mem.zeroes(libc.FILETIME);
        var lp_kernel_time = std.mem.zeroes(libc.FILETIME);
        var lp_user_time = std.mem.zeroes(libc.FILETIME);

        if (libc.GetProcessTimes(
            proc_handle,
            &lp_creation_time,
            &lp_exit_time,
            &lp_kernel_time,
            &lp_user_time
        ) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToGetProcessStats;
        }

        const creation_time = winutil.combine_filetime(&lp_creation_time);
        const start_time = winutil.convert_filetime64_to_unix_epoch(creation_time);
        const kernel_time = winutil.combine_filetime(&lp_kernel_time);
        const user_time = winutil.combine_filetime(&lp_user_time);

        return .{ start_time, kernel_time, user_time };
    }

    fn get_job_handle(self: *Self) Errors!?*anyopaque {
        var job_name = std.fmt.allocPrintZ(util.gpa, "Global\\mult-{d}", .{self.task.id})
        catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        job_name[job_name.len] = 0;
        defer util.gpa.free(job_name);
        const job_handle = libc.OpenJobObjectA(
            libc.JOB_OBJECT_ALL_ACCESS, 1, job_name.ptr
        );
        if (job_handle == null) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToGetProcess;
        }
        return job_handle;
    }

    pub fn get_child_pids(self: *Self) Errors![]util.Pid {
        if (!self.proc_exists()) {
            return .{};
        }
        var jobs = std.mem.zeroes(Jobs); 
        const job_handle = try self.get_job_handle();
        defer {
            _ = libc.CloseHandle(job_handle);
        }
        if (libc.QueryInformationJobObject(
            job_handle,
            libc.JobObjectBasicProcessIdList,
            &jobs,
            @sizeOf(Jobs),
            null
        ) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToGetProcessChildren;
        }

        return std.mem.trimRight(u8, jobs.list, &[1]u8{0});
    }

    pub fn get_all_processes(self: *Self) Errors!*Self {
        if (!self.proc_exists()) {
            return self;
        }

        // Set this process' stats
        const self_stats = try self.get_stats();
        self.start_time = self_stats[0];
        self.cpu.old_stime = self.cpu.stime;
        self.cpu.old_utime = self.cpu.utime;
        self.cpu.stime = self_stats[1];
        self.cpu.utime = self_stats[2];

        // Set process children's stats
        var job_name = std.fmt.allocPrintZ(util.gpa, "Global\\mult-{d}", .{self.task.id})
        catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        job_name[job_name.len] = 0;
        defer util.gpa.free(job_name);
        const job_handle = libc.OpenJobObjectA(
            libc.JOB_OBJECT_ALL_ACCESS, 1, job_name.ptr
        );
        defer {
            _ = libc.CloseHandle(job_handle);
        }

        var jobs = std.mem.zeroes(Jobs);

        const res = libc.QueryInformationJobObject(
            job_handle,
            libc.JobObjectBasicProcessIdList,
            &jobs,
            @sizeOf(Jobs),
            null
        );
        if (res == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToGetProcessChildren;
        }
        var new_proc_list = std.ArrayList(Self).init(util.gpa);
        defer new_proc_list.deinit();
        // Probably need to add checks for if the proc exists before overwriting it for old_s/utimes
        // turns out i need to do this
        for (jobs.list) |pid| {
            if (pid != 0 and pid != self.pid) {
                var exists = false;
                for (self.children) |child| {
                    if (child.pid == pid) {
                        exists = true;
                        var proc = child; // Need to make mutable clone
                        proc.cpu.old_stime = child.cpu.stime;
                        proc.cpu.old_utime = child.cpu.utime;
                        const new_stats = try child.get_stats();
                        proc.start_time = new_stats[0];
                        proc.cpu.stime = new_stats[1];
                        proc.cpu.utime = new_stats[2];
                        new_proc_list.append(proc)
                            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                    }
                }

                if (!exists) {
                    var proc = try Self.init(pid, self.task);
                    const stats = try proc.get_stats();
                    proc.start_time = stats[0];
                    proc.cpu.stime = stats[1];
                    proc.cpu.utime = stats[2];
                    new_proc_list.append(proc)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
                }
            }
        }
        self.children = new_proc_list.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        return self;
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
            var pmap_buf: [Lengths.TINY]u8 = undefined;
            const pid_str: []u8 = std.fmt.bufPrint(&pmap_buf, "{d}:{d},", .{
                self.pid, self.start_time
            }) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);
            proc_string.appendSlice(try util.strdup(pid_str, error.FailedToSaveProcesses))
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);

            original.keep_running = true;

            // Saving cpu usage
            const cpu_usage = try self.cpu.get_cpu_usage();
            self.cpu.set_cpu_time_total();

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

        const processes = std.fmt.allocPrint(util.gpa, "{s})", .{
            std.mem.sliceTo(&original.file_strings.processes, 0),
        }) catch |err| return e.verbose_error(err, error.FailedToSaveProcesses);
        util.gpa.free(processes);

        std.mem.copyForwards(u8, &original.file_strings.processes, processes);
    }

    pub fn get_runtime(self: *Self) Errors!u64 {
        if (self.start_time == 0) {
            const stats = try self.get_stats();
            self.start_time = stats[0];
        }
        const secs_since_epoch: u64 = @intCast(std.time.timestamp());
        return secs_since_epoch - self.start_time;
    }

    pub fn get_memory(self: *Self) Errors!u64 {
        const proc_handle = libc.OpenProcess(libc.PROCESS_QUERY_INFORMATION, 1, self.pid);
        if (proc_handle == null) {
            return 0;
        }

        var mem_info: libc.PROCESS_MEMORY_COUNTERS = std.mem.zeroes(libc.PROCESS_MEMORY_COUNTERS);
        if (libc.GetProcessMemoryInfo(
            proc_handle,
            &mem_info,
            @sizeOf(libc.PROCESS_MEMORY_COUNTERS)
        ) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToGetProcessMemory;
        }
        return mem_info.WorkingSetSize;
    }

    pub fn get_exe(self: *Self) Errors![]const u8 {
        const proc_handle = libc.OpenProcess(libc.PROCESS_QUERY_INFORMATION, 1, self.pid);
        if (proc_handle == null) {
            return "";
        }
        var proc_name: [Lengths.LARGE]u8 = std.mem.zeroes([Lengths.LARGE]u8);
        if (libc.GetProcessImageFileNameA(proc_handle, &proc_name, Lengths.LARGE) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToGetProcessComm;
        }

        var itr_proc_name = std.mem.splitScalar(u8, &proc_name, '\\');
        while (itr_proc_name.next()) |it| {
            if (itr_proc_name.peek() == null) {
                // For some reason, after the null terminator the buffer sometimes gets filled with the 170 char 'ª'
                const trimmed_exe = std.mem.trimRight(u8, it, &[2]u8{170, 0});
                return util.strdup(trimmed_exe, error.FailedToGetProcessComm);
            }
        }
        return "";
    }

    pub fn check_mem_overflowing_procs(self: *Self) Errors!void {
        for (self.children) |*child| {
            if (try child.get_memory() > child.task.stats.memory_limit) {
                try child.kill();
            }
        }
        if (try self.get_memory() > self.task.stats.memory_limit) {
            try self.kill();
        }
    }
};
