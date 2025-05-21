const libc = @import("../c.zig").libc;
const std = @import("std");
const util = @import("../util.zig");
const SysTimes = util.SysTimes;
const Lengths = util.Lengths;
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

    pub var usage_stats: std.AutoHashMap(Pid, SysTimes) =
        std.AutoHashMap(Pid, SysTimes).init(util.gpa);
    pub var time_total: u64 = 0;

    // cpu_time_total: u64 = 0,
    // old_utime: u64 = 0,
    // old_stime: u64 = 0,
    // utime: u64 = 0,
    // stime: u64 = 0,

    // pub fn init() Self {
    //     var cpu = Self {};
    //     cpu.set_cpu_time_total();
    //     return cpu;
    // }

    pub fn deinit() void {
        usage_stats.clearAndFree();
        usage_stats.deinit();
    }

    pub fn update_time_total() void {
        var ft: libc.FILETIME = std.mem.zeroes(libc.FILETIME);
        libc.GetSystemTimeAsFileTime(&ft);
        WindowsCpu.time_total = winutil.combine_filetime(&ft);
    }

    fn get_proc_count() u32 {
        var system_info: libc.SYSTEM_INFO = std.mem.zeroes(libc.SYSTEM_INFO);
        libc.GetSystemInfo(&system_info);
        return system_info.dwNumberOfProcessors;
    }

    pub fn get_cpu_usage(
        process: *WindowsProcess
    ) Errors!f64 {
        const processor_count = get_proc_count();
        var now: libc.FILETIME = std.mem.zeroes(libc.FILETIME);
        libc.GetSystemTimeAsFileTime(&now);
        const old_proc_times_struct = usage_stats.get(process.pid);
        if (old_proc_times_struct == null) {
            usage_stats.put(process.pid, SysTimes {
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
        const time_delta: u64 = time - time_total;
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
        const val = usage_stats.getOrPut(process.pid)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        val.value_ptr.*.utime = utime;
        val.value_ptr.*.stime = stime;
        return usage;
    }
};