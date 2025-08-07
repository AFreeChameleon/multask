const std = @import("std");
const Task = @import("./index.zig").Task;

const util = @import("../util.zig");
const Lengths = util.Lengths;

const e = @import("../error.zig");
const Errors = e.Errors;

pub const Resources = struct {
    cpu: std.AutoHashMap(util.Pid, f64) = undefined,

    pub fn deinit(self: *Resources) void {
        self.cpu.deinit();
    }

    pub fn set_cpu_usage(self: *Resources) Errors!void {
        const task: *Task = @fieldParentPtr("resources", self);
        self.cpu = try get_cpu_usage(task);
    }

    fn get_cpu_usage(task: *Task) Errors!std.AutoHashMap(util.Pid, f64) {
        var cpu_usage_map: std.AutoHashMap(util.Pid, f64) =
            std.AutoHashMap(util.Pid, f64).init(util.gpa);
        defer cpu_usage_map.deinit();

        const usage_file = try task.files.get_file("usage");
        defer usage_file.close();
        usage_file.seekTo(0)
            catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        var buf_reader = std.io.bufferedReader(usage_file.reader());
        var reader = buf_reader.reader();
        var buf: [Lengths.MEDIUM]u8 = std.mem.zeroes([Lengths.MEDIUM]u8);
        var buf_fbs = std.io.fixedBufferStream(&buf);
        while (
            true
        ) {
            reader.streamUntilDelimiter(buf_fbs.writer(), '|', buf_fbs.buffer.len)
                catch |err| switch (err) {
                    error.NoSpaceLeft => break,
                    error.EndOfStream => break,
                    else => |inner_err| return e.verbose_error(
                        inner_err, error.FailedToGetCpuUsage
                    )
                };
            const it = buf_fbs.getWritten();
            defer buf_fbs.reset();
            if (it.len == 0) {
                break;
            }
            var split_line = std.mem.splitSequence(u8, it, ":");
            const str_pid = split_line.next();
            if (str_pid == null) {
                break;
            }

            const pid = std.fmt.parseInt(util.Pid, str_pid.?, 10)
                catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);

            const str_cpu_usage = split_line.next();
            if (str_cpu_usage == null) {
                break;
            }
            const cpu_usage = std.fmt.parseFloat(f64, str_cpu_usage.?)
                catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);

            cpu_usage_map.put(pid, cpu_usage)
                catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        }
        return cpu_usage_map.clone()
            catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
    }
};
