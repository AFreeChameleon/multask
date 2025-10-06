const std = @import("std");

const log = @import("../log.zig");
const util = @import("../util.zig");
const Lengths = util.Lengths;
const TaskId = @import("../task/index.zig").TaskId;
const TaskManager = @import("../task/manager.zig").TaskManager;
const MainFiles = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

const ChildProcess = std.process.Child;

/// Checks if the mlt startup command is being ran at startup
fn get_crontab() Errors![]u8 {
    var child = ChildProcess.init(&[_][]const u8{"crontab", "-l"}, util.gpa);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn()
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);

    var stdout = child.stdout.?.reader();
    var buffer = std.ArrayList(u8).init(util.gpa);
    defer buffer.deinit();

    _ = stdout.readAllArrayList(&buffer, Lengths.HUGE)
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);

    _ = child.wait()
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);

    return buffer.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);
}

fn CalcStartupCommandLen() usize {
    return std.fs.max_path_bytes + "@reboot ".len + " startup".len + 1;
}

fn get_mlt_startup_crontab() Errors![]u8 {
    const exe_path = try util.get_mlt_exe_path();

    const buf_len = comptime CalcStartupCommandLen();
    var buf: [buf_len]u8 = std.mem.zeroes([buf_len]u8);

    const startup = std.fmt.bufPrint(&buf, "@reboot {s} startup\n", .{exe_path})
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    return startup;
}

fn add_crontab(cron: []u8, startup_cmd: []u8) Errors!void {
    var child = ChildProcess.init(&[_][]const u8{"crontab", "-"}, util.gpa);
    child.stdin_behavior = .Pipe;

    child.spawn()
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);

    if (child.stdin == null) {
        return error.FailedToSetStartupDetails;
    }

    const stdin_writer = child.stdin.?.writer();

    _ = stdin_writer.write(cron)
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);

    if (cron.len > 0 and cron[cron.len - 1] != '\n') {
        _ = stdin_writer.writeByte('\n')
            catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    }

    _ = stdin_writer.write(startup_cmd)
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);

    child.stdin.?.close();
    child.stdin = null;

    const res = child.wait()
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);

    if (res.Exited != 0) {
        return error.FailedToSetStartupDetails;
    }
}

/// Checks if the mlt startup command is being ran at startup
pub fn set_run_on_boot() Errors!void {
    const cron = try get_crontab();
    defer util.gpa.free(cron);

    const startup_cmd = try get_mlt_startup_crontab();

    if (std.mem.indexOf(u8, cron, startup_cmd) != null) {
        return;
    }

    try add_crontab(cron, startup_cmd);
}

