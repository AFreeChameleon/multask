const libc = @import("../c.zig").libc;
const std = @import("std");
const util = @import("../util.zig");
const macutil = @import("./util.zig");
const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const Pid = @import("../util.zig").Pid;
const MacosProcess = @import("./process.zig").MacosProcess;

const e = @import("../error.zig");
const Errors = e.Errors;

// 0 -> utime, 1 -> stime
pub var usage_stats: std.AutoHashMap(Pid, [2]u64) =
    std.AutoHashMap(Pid, [2]u64).init(util.gpa);

pub const MacosCpu = struct {
    const Self = @This();

    time_total: u64 = 0,
    old_utime: u64 = 0,
    old_stime: u64 = 0,
    utime: u64 = 0,
    stime: u64 = 0,

    pub fn init() Self {
        return Self {};
    }

    pub fn get_cpu_usage(
        self: *Self
    ) Errors!f64 {
        const total_existing_time_ns =
            macutil.mach_ticks_to_nanoseconds(self.old_utime) +
            macutil.mach_ticks_to_nanoseconds(self.old_stime);

        const user_time_ns = macutil.mach_ticks_to_nanoseconds(
            self.utime
        );
        const system_time_ns = macutil.mach_ticks_to_nanoseconds(
            self.stime
        );
        const total_current_time_ns = user_time_ns + system_time_ns;

        if (total_current_time_ns != 0) {
            const total_time_diff_ns = total_current_time_ns -
                total_existing_time_ns;
            const usage = (
                @as(f64, @floatFromInt(total_time_diff_ns)) / macutil.TIME_INTERVAL
            ) * 100.0;
            self.time_total = total_current_time_ns;
            return usage;
        } else {
            return 0.0;
        }
    }
};
