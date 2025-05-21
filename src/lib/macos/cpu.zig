const libc = @import("../c.zig").libc;
const std = @import("std");
const util = @import("../util.zig");
const SysTimes = util.SysTimes;
const macutil = @import("./util.zig");
const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const Pid = @import("../util.zig").Pid;
const MacosProcess = @import("./process.zig").MacosProcess;

const e = @import("../error.zig");
const Errors = e.Errors;

pub const MacosCpu = struct {
    const Self = @This();

    pub var usage_stats: std.AutoHashMap(Pid, SysTimes) =
        std.AutoHashMap(Pid, SysTimes).init(util.gpa);

    pub var time_total: u64 = 0;

    pub fn deinit() void {
        usage_stats.clearAndFree();
        usage_stats.deinit();
    }

    pub fn get_cpu_usage(
        process: *MacosProcess
    ) Errors!f64 {
        const old_times = usage_stats.get(process.pid);
        if (old_times == null) {
            usage_stats.put(process.pid, SysTimes {
                .utime = 0,
                .stime = 0,
            }) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
            return 0.0;
        }
        const total_existing_time_ns =
            macutil.mach_ticks_to_nanoseconds(old_times.?.utime) +
            macutil.mach_ticks_to_nanoseconds(old_times.?.stime);
        const taskinfo = try process.get_task_stats();

        const user_time_ns = macutil.mach_ticks_to_nanoseconds(
            taskinfo.pti_total_user
        );
        const system_time_ns = macutil.mach_ticks_to_nanoseconds(
            taskinfo.pti_total_system
        );
        const total_current_time_ns = user_time_ns + system_time_ns;

        if (total_current_time_ns != 0) {
            const total_time_diff_ns = total_current_time_ns -
                total_existing_time_ns;
            const usage = (
                @as(f64, @floatFromInt(total_time_diff_ns)) / macutil.TIME_INTERVAL
            ) * 100.0;
            usage_stats.put(process.pid, SysTimes {
                .utime = taskinfo.pti_total_user,
                .stime = taskinfo.pti_total_system,
            }) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
            return usage;
        } else {
            return 0.0;
        }
    }

    pub fn update_time_total(process: *MacosProcess) Errors!void {
        const taskinfo = try process.get_task_stats();

        const user_time_ns = macutil.mach_ticks_to_nanoseconds(
            taskinfo.pti_total_user
        );
        const system_time_ns = macutil.mach_ticks_to_nanoseconds(
            taskinfo.pti_total_system
        );
        time_total = user_time_ns + system_time_ns;
    }
};
