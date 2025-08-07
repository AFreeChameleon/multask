const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const Lengths = util.Lengths;
const Pid = util.Pid;

const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const LinuxProcess = @import("./process.zig").LinuxProcess;
const e = @import("../error.zig");
const Errors = e.Errors;

pub var usage_stats: std.AutoHashMap(Pid, [2]u64) =
    std.AutoHashMap(Pid, [2]u64).init(util.gpa);

pub const LinuxCpu = struct {
    const Self = @This();

    time_total: u64 = 0,
    old_utime: u64 = 0,
    old_stime: u64 = 0,
    utime: u64 = 0,
    stime: u64 = 0,

    pub fn init() Self {
        return Self {};
    }

    pub fn get_cpu_time_total(_: *Self, cpu_stats: [][]const u8) u64 {
        var time_total: u64 = 0;
        for (cpu_stats) |str_time| {
            const time = std.fmt.parseInt(u64, str_time, 10)
                catch continue;
            time_total += time;
        }
        return time_total;
    }

    pub fn get_cpu_stats(_: *Self) Errors![][]const u8 {
        var stats = std.ArrayList([]const u8).init(util.gpa);
        defer stats.deinit();
        var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const stat_path = std.fs.realpath("/proc/stat", &out_buffer)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        const stat_file = std.fs.openFileAbsolute(stat_path, .{.mode = .read_only})
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        defer stat_file.close();

        var stat_buf = std.io.bufferedReader(stat_file.reader());
        var stat_reader = stat_buf.reader();
        var buf: [Lengths.LARGE]u8 = undefined;
        const cpu_line = stat_reader.readUntilDelimiterOrEof(&buf, '\n')
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        if (cpu_line == null) {
            return &.{};
        }

        var split_cpu_line = std.mem.splitSequence(u8, cpu_line.?, " ");
        while (split_cpu_line.next()) |stat| {
            stats.append(try util.strdup(stat, error.FailedToGetCpuStats))
                catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        }

        return stats.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
    }

    pub fn get_cpu_usage(
        self: *Self,
        cpu_time_total: u64
    ) Errors!f64 {
        const cpu_stats = try self.get_cpu_stats();
        const old_proc_times = self.old_utime + self.old_stime;
        const proc_times = self.utime + self.stime;
        const total_time = self.get_cpu_time_total(cpu_stats);
        const cpu_usage: f64 = @as(f64, @floatFromInt(libc.sysconf(libc._SC_NPROCESSORS_ONLN)))
            * 100.0
            * (
                (@as(f64, @floatFromInt(proc_times)) - @as(f64, @floatFromInt(old_proc_times))) /
                (@as(f64, @floatFromInt(total_time)) - @as(f64, @floatFromInt(cpu_time_total)))
            );
        if (cpu_usage == std.math.inf(@TypeOf(cpu_usage))) {
            return error.FailedToGetCpuUsage;
        }
        return cpu_usage;
    }
};
