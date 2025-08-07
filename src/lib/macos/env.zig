const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const Lengths = util.Lengths;
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const FileStrings = util.FileStrings;
const e = @import("../error.zig");
const Errors = e.Errors;
const Find = @import("../file.zig").Find;

const log = @import("../log.zig");

const t = @import("../task/index.zig");
const TaskFiles = t.Files;
const Task = t.Task;
const TaskId = t.TaskId;

const MainFiles = @import("../file.zig").MainFiles;
const Cpu = @import("./cpu.zig");
const MacosCpu = Cpu.MacosCpu;

const taskproc = @import("../task/process.zig");
const CpuStatus = taskproc.CpuStatus;

const f = @import("../task/file.zig");
const ReadProcess = f.ReadProcess;

const procstats = @import("./stats.zig");

const MULTASK_TASK_ID = [_]u8 {
    'M', 'U', 'L', 'T', 'A', 'S', 'K', '_', 'T', 'A', 'S', 'K', '_', 'I', 'D', '='
};

pub fn proc_has_taskid_in_env(pid: Pid, task_id: TaskId) Errors!bool {
    var mib = [_]c_int{ libc.CTL_KERN, libc.KERN_PROCARGS2, pid };
    var size: usize = 0;

    if (libc.sysctl(&mib, @sizeOf(@TypeOf(mib)), null, &size, null, 0) != 0) {
        try log.printdebug("get_env_block: Macos LIBC error {d}", .{libc.__error().*});
        return error.FailedToGetEnvs;
    }

    const buffer = util.gpa.alloc(u8, size)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
    defer util.gpa.free(buffer);

    if (libc.sysctl(&mib, @sizeOf(@TypeOf(mib)), buffer.ptr, &size, null, 0) != 0) {
        try log.printdebug("get_env_block: Macos LIBC error {d}", .{libc.__error().*});
        return error.FailedToGetEnvs;
    }

    // First 4 bytes are argc
    const argc_string = buffer[0..4];
    var argc_arr: [4]u8 = std.mem.zeroes([4]u8);
    @memcpy(&argc_arr, argc_string.ptr);
    const argc: i32 = @bitCast(argc_arr);

    const start_idx: usize = @sizeOf(@TypeOf(argc)) + @as(usize, @intCast(argc));
    var iter = std.mem.splitScalar(u8, buffer[start_idx..], 0);
    var i: usize = 0;
    while (iter.next()) |env_pair| {
        if (env_pair.len == 0) continue;
        defer i += 1;
        if (i <= argc) continue;
        if (env_pair.len < MULTASK_TASK_ID.len) continue;

        const key_idx = std.mem.indexOf(u8, env_pair, &MULTASK_TASK_ID);
        if (key_idx == null or key_idx.? != 0) continue;

        const val_idx = MULTASK_TASK_ID.len;
        const id_string = env_pair[val_idx..];
        const id = std.fmt.parseInt(TaskId, id_string, 10)
            catch continue;
        if (id == task_id) {
            return true;
        }
    }

    return false;
}
