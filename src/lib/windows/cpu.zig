const libc = @import("../c.zig").libc;
const std = @import("std");
const util = @import("../util.zig");
const Lengths = util.Lengths;
const Pid = util.Pid;

const winutil = @import("./util.zig");

const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const LinuxProcess = @import("./process.zig").LinuxProcess;
const e = @import("../error.zig");
const Errors = e.Errors;

pub const WindowsCpu = struct {
    const Self = @This();

    cpu_time_total: u64 = 0,
    old_utime: u64 = 0,
    old_stime: u64 = 0,
    utime: u64 = 0,
    stime: u64 = 0,

    pub fn init() Self {
        var cpu = Self {};
        cpu.set_cpu_time_total();
        return cpu;
    }

    pub fn set_cpu_time_total(self: *Self) void {
        var ft: libc.FILETIME = std.mem.zeroes(libc.FILETIME);
        libc.GetSystemTimeAsFileTime(&ft);
        self.cpu_time_total = winutil.combine_filetime(&ft);
    }

    fn get_proc_count() u32 {
        var system_info: libc.SYSTEM_INFO = std.mem.zeroes(libc.SYSTEM_INFO);
        libc.GetSystemInfo(&system_info);
        return system_info.dwNumberOfProcessors;
    }

    pub fn get_cpu_usage(
        self: *Self
    ) Errors!f64 {
        const processor_count = get_proc_count();
        var now: libc.FILETIME = std.mem.zeroes(libc.FILETIME);
        libc.GetSystemTimeAsFileTime(&now);
        const system_time = self.utime + self.stime;
        const last_system_time = self.old_utime + self.old_stime;
        const time = winutil.combine_filetime(&now);
        const system_time_delta: u64 = system_time - last_system_time;
        const time_delta: u64 = time - self.cpu_time_total;
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
        return usage;
    }
};