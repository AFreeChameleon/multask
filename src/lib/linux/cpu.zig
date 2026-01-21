const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const SysTimes = util.SysTimes;
const Pid = util.Pid;

const t = @import("../task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const MainFiles = @import("../file.zig").MainFiles;
const LinuxProcess = @import("./process.zig").LinuxProcess;
const e = @import("../error.zig");
const Errors = e.Errors;
const ProcFs = @import("./file.zig").ProcFs;

pub const LinuxCpu = struct {
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

    fn get_cpu_time_total() u64 {
        var content_buf: [4096]u8 = undefined;
        const cpu_line = ProcFs.read_file_until_delimiter_buf(null, &content_buf, '\n', .RootStat)
            catch return 0;

        var split_cpu_line = std.mem.splitSequence(u8, cpu_line, " ");
        var cpu_time_total: u64 = 0;

        while (split_cpu_line.next()) |str_time| {
            if (str_time.len != 0 and util.is_number(str_time)) {
                const time = std.fmt.parseInt(u64, str_time, 10)
                    catch continue;
                cpu_time_total += time;
            }
        }
        return cpu_time_total;
    }

    fn read_utime_stime(pid: Pid) Errors!struct {utime: u64, stime: u64} {
        var utime: u64 = 0;
        var stime: u64 = 0;

        var content_buf: [4096]u8 = undefined;
        const content = try ProcFs.read_file_buf(pid, &content_buf, .Stat);
        var stat_time_buf: [4096]u8 = undefined;

        const stat_utime = try ProcFs.extract_stat_buf(&stat_time_buf, content, 13);
        if (stat_utime != null) {
            utime = std.fmt.parseInt(u64, stat_utime.?, 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }
        const stat_stime = try ProcFs.extract_stat_buf(&stat_time_buf, content, 14);
        if (stat_stime != null) {
            stime = std.fmt.parseInt(u64, stat_stime.?, 10)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }
        return .{ .utime = utime, .stime = stime };
    }

    pub fn get_cpu_usage(
        self: *Self,
        process: *LinuxProcess,
    ) Errors!f64 {
        var utime: u64 = 0;
        var stime: u64 = 0;

        const res = try read_utime_stime(process.pid);
        utime = res.utime;
        stime = res.stime;

        const old_proc_times_struct = self.systimes.get(process.pid);
        if (old_proc_times_struct == null) {
            self.systimes.put(process.pid, SysTimes {
                .utime = 0,
                .stime = 0,
            }) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
            return 0.0;
        }
        const old_proc_times = old_proc_times_struct.?.utime + old_proc_times_struct.?.stime;
        const proc_times = utime + stime;
        const new_time_total = get_cpu_time_total();
        const cpu_usage: f64 = @as(f64, @floatFromInt(libc.sysconf(libc._SC_NPROCESSORS_ONLN)))
            * 100.0
            * (
                (@as(f64, @floatFromInt(proc_times)) - @as(f64, @floatFromInt(old_proc_times))) /
                (@as(f64, @floatFromInt(new_time_total)) - @as(f64, @floatFromInt(self.time_total)))
            );

        // Set 'old' data for next iteration
        const val = self.systimes.getOrPut(process.pid)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        val.value_ptr.*.utime = utime;
        val.value_ptr.*.stime = stime;

        if (cpu_usage == std.math.inf(@TypeOf(cpu_usage))) {
            return error.FailedToGetCpuUsage;
        }
        return cpu_usage;
    }

    pub fn update_time_total(self: *Self) Errors!void {
        self.time_total = get_cpu_time_total();
    }
};
