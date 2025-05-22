const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const SysTimes = util.SysTimes;
const Lengths = util.Lengths;
const Pid = util.Pid;

const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const LinuxProcess = @import("./process.zig").LinuxProcess;
const e = @import("../error.zig");
const Errors = e.Errors;

pub const LinuxCpu = struct {
    const Self = @This();

    pub var usage_stats: std.AutoHashMap(Pid, SysTimes) =
        std.AutoHashMap(Pid, SysTimes).init(util.gpa);
    pub var time_total: u64 = 0;

    pub fn deinit() void {
        usage_stats.clearAndFree();
        usage_stats.deinit();
    }

    pub fn get_cpu_time_total(cpu_stats: [][]const u8) u64 {
        var cpu_time_total: u64 = 0;
        for (cpu_stats) |str_time| {
            const time = std.fmt.parseInt(u64, str_time, 10)
                catch continue;
            cpu_time_total += time;
        }
        return cpu_time_total;
    }

    pub fn get_cpu_stats() Errors![][]const u8 {
        var stats = std.ArrayList([]const u8).init(util.gpa);
        defer stats.deinit();
        const stat_path = std.fs.realpathAlloc(util.gpa, "/proc/stat")
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        defer util.gpa.free(stat_path);
        const stat_file = std.fs.openFileAbsolute(stat_path, .{.mode = .read_only})
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        defer stat_file.close();

        var stat_buf = std.io.bufferedReader(stat_file.reader());
        var stat_reader = stat_buf.reader();
        const cpu_line = stat_reader.readUntilDelimiterOrEofAlloc(util.gpa, '\n', Lengths.LARGE)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        if (cpu_line == null) {
            return &.{};
        }
        defer util.gpa.free(cpu_line.?);

        var split_cpu_line = std.mem.splitSequence(u8, cpu_line.?, " ");
        while (split_cpu_line.next()) |stat| {
            stats.append(try util.strdup(stat, error.FailedToGetCpuStats))
                catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
        }

        return stats.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetCpuStats);
    }

    pub fn get_cpu_usage(
        process: *LinuxProcess,
    ) Errors!f64 {
        const stats = try process.get_process_stats();
        defer {
            for (stats) |stat| {
                util.gpa.free(stat);
            }
            util.gpa.free(stats);
        }
        var utime: u64 = 0;
        var stime: u64 = 0;
        if (stats.len > 0) {
            utime = std.fmt.parseInt(u64, stats[13], 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
            stime = std.fmt.parseInt(u64, stats[14], 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }

        const old_proc_times_struct = usage_stats.get(process.pid);
        if (old_proc_times_struct == null) {
            usage_stats.put(process.pid, SysTimes {
                .utime = 0,
                .stime = 0,
            }) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
            return 0.0;
        }
        const old_proc_times = old_proc_times_struct.?.utime + old_proc_times_struct.?.stime;
        const proc_times = utime + stime;
        const cpu_stats = try get_cpu_stats();
        defer {
            for (cpu_stats) |stat| {
                util.gpa.free(stat);
            }
            util.gpa.free(cpu_stats);
        }
        const new_time_total = get_cpu_time_total(cpu_stats);
        const cpu_usage: f64 = @as(f64, @floatFromInt(libc.sysconf(libc._SC_NPROCESSORS_ONLN)))
            * 100.0
            * (
                (@as(f64, @floatFromInt(proc_times)) - @as(f64, @floatFromInt(old_proc_times))) /
                (@as(f64, @floatFromInt(new_time_total)) - @as(f64, @floatFromInt(time_total)))
            );

        // Set 'old' data for next iteration
        const val = usage_stats.getOrPut(process.pid)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        val.value_ptr.*.utime = utime;
        val.value_ptr.*.stime = stime;

        if (cpu_usage == std.math.inf(@TypeOf(cpu_usage))) {
            return error.FailedToGetCpuUsage;
        }
        return cpu_usage;
    }

    pub fn update_time_total() Errors!void {
        const cpu_stats = try get_cpu_stats();
        defer {
            for (cpu_stats) |stat| {
                util.gpa.free(stat);
            }
            util.gpa.free(cpu_stats);
        }
        time_total = get_cpu_time_total(cpu_stats);
    }
};
