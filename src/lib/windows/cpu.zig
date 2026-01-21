const libc = @import("../c.zig").libc;
const std = @import("std");
const util = @import("../util.zig");
const SysTimes = util.SysTimes;
const Pid = util.Pid;

const winutil = @import("./util.zig");

const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const WindowsProcess = @import("./process.zig").WindowsProcess;
const e = @import("../error.zig");
const Errors = e.Errors;

pub const WindowsCpu = struct {
    const Self = @This();

    systimes: std.AutoHashMap(Pid, SysTimes),
    time_total: u64,

    pub fn init() Self {
        return Self {
            .systimes = std.AutoHashMap(Pid, SysTimes).init(util.gpa),
            .time_total = 0
        };
    }

    pub fn deinit(self: *Self) void {
        self.systimes.clearAndFree();
        self.systimes.deinit();
    }

    pub fn clone(self: *Self) Errors!Self {
        return Self {
            .systimes = self.systimes.clone()
                catch |err| return e.verbose_error(err, error.FailedToGetCpuStats),
            .time_total = self.time_total
        };
    }

    pub fn update_time_total(self: *Self) void {
        var ft: libc.FILETIME = std.mem.zeroes(libc.FILETIME);
        libc.GetSystemTimeAsFileTime(&ft);
        self.time_total = winutil.combine_filetime(&ft);
    }

    fn get_proc_count() u32 {
        var system_info: libc.SYSTEM_INFO = std.mem.zeroes(libc.SYSTEM_INFO);
        libc.GetSystemInfo(&system_info);
        return system_info.dwNumberOfProcessors;
    }

    pub fn get_cpu_usage(
        self: *Self,
        process: *WindowsProcess
    ) Errors!f64 {
        const processor_count = get_proc_count();
        var now: libc.FILETIME = std.mem.zeroes(libc.FILETIME);
        libc.GetSystemTimeAsFileTime(&now);
        const old_proc_times_struct = self.systimes.get(process.pid);
        if (old_proc_times_struct == null) {
            self.systimes.put(process.pid, SysTimes {
                .utime = 0,
                .stime = 0,
            }) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
            return 0.0;
        }
        const stats = try process.get_stats();
        const utime = stats[1];
        const stime = stats[2];
        const system_time = utime + stime;
        const last_system_time = old_proc_times_struct.?.utime + old_proc_times_struct.?.stime;
        const time = winutil.combine_filetime(&now);
        const system_time_delta: u64 = system_time - last_system_time;
        const time_delta: u64 = time - self.time_total;
        // Happens when starting off
        if (time_delta == 0) {
            return 0.0;
        }
        const usage: f64 = (
            (@as(f64, @floatFromInt(system_time_delta)) * 100 + @as(f64, @floatFromInt(time_delta)) / 2) /
            @as(f64, @floatFromInt(time_delta))
        ) / @as(f64, @floatFromInt(processor_count));
        if (usage == std.math.inf(@TypeOf(usage))) {
            return error.FailedToGetCpuUsage;
        }
        // Set 'old' data for next iteration
        const val = self.systimes.getOrPut(process.pid)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        val.value_ptr.*.utime = utime;
        val.value_ptr.*.stime = stime;
        return usage;
    }
};
