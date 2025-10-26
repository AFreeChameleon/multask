const libc = @import("../c.zig").libc;
const std = @import("std");
const log = @import("../log.zig");

const e = @import("../error.zig");
const Errors = e.Errors;

const util = @import("../util.zig");
const ForkFlags = util.ForkFlags;

const win_util = @import("./util.zig");

const MainFiles = @import("../file.zig").MainFiles;

const t = @import("../task/index.zig");
const Task = t.Task;
const Files = t.Files;

const TaskLogger = @import("../task/logger.zig");

const taskproc = @import("../task/process.zig");
const Process = taskproc.Process;
const ExistingLimits = taskproc.ExistingLimits;

const ChildProcess = std.process.Child;

pub fn run_daemon(task: *Task, flags: ForkFlags) Errors!void {
    try util.save_stats(task, &flags);

    if (flags.interactive != null and flags.interactive.?) {
        try log.printwarn("Interactive flag is on by default on Windows.", .{});
    }

    var envs = try taskproc.get_envs(task, flags.update_envs);
    defer envs.deinit();
    if (flags.no_run) {
        return;
    }

    const exe_path = std.fs.selfExePathAlloc(util.gpa) catch |err| return e.verbose_error(err, error.SpawnExeNotFound);
    defer util.gpa.free(exe_path);
    const opt_exe_dir = std.fs.path.dirname(exe_path);
    if (opt_exe_dir == null) {
        std.debug.print("could not find the exe path properly: {s}\n", .{exe_path});
        return error.SpawnExeNotFound;
    }

    // Convert to utf16 = https://ziglang.org/documentation/master/std/#std.unicode.utf8ToUtf16LeAlloc
    // In the future, just make the exe read from the file for it's limits, only pass in the task id.
    const proc_string = std.fmt.allocPrintZ(util.gpa, "{s}\\spawn.exe {d}", .{ opt_exe_dir.?, task.id }) catch |err| return e.verbose_error(err, error.ForkFailed);
    defer util.gpa.free(proc_string);
    var proc_info: libc.PROCESS_INFORMATION = std.mem.zeroes(libc.PROCESS_INFORMATION);
    var si: libc.STARTUPINFOEXA = std.mem.zeroes(libc.STARTUPINFOEXA);
    si.StartupInfo.cb = @sizeOf(libc.STARTUPINFOEXA);

    var create_proc_flags: c_ulong = libc.CREATE_NO_WINDOW;
    if (win_util.can_breakaway()) {
        create_proc_flags |= libc.CREATE_BREAKAWAY_FROM_JOB;
    }

    const res = libc.CreateProcessA(null, proc_string.ptr, null, null, 0, create_proc_flags, null, null, @as([*c]libc.STARTUPINFOA, @ptrCast(&si.StartupInfo)), @as([*c]libc.PROCESS_INFORMATION, @ptrCast(&proc_info)));
    if (res == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        std.debug.print("Windows error code WHY DOES SPAWNING FAIL: {d}", .{std.os.windows.GetLastError()});
        return error.SpawnExeNotFound;
    }
}
