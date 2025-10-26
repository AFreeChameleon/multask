const std = @import("std");
const libc = @import("../c.zig").libc;
const util = @import("../util.zig");
const Pid = util.Pid;
const Pgrp = util.Pgrp;
const Sid = util.Sid;
const e = @import("../error.zig");
const Errors = e.Errors;
const Find = @import("../file.zig").Find;
const log = @import("../log.zig");


pub fn get_pgrp(stats: *const libc.proc_bsdinfo) Pgrp {
    return stats.pbi_pgid;
}

pub fn get_starttime(stats: *const libc.proc_bsdinfo) u64 {
    return stats.pbi_start_tvsec;
}

pub fn get_ppid(stats: *const libc.proc_bsdinfo) Errors!Pid {
    const ppid = stats.pbi_ppid; // Returns a u32 even though ITS A PROCESS ID???? Im going mad
    if (ppid > std.math.maxInt(Pid)) {
        return error.FailedToGetProcessPpid;
    }
    return @intCast(ppid);
}

pub fn get_exe(stats: *const libc.proc_bsdinfo) []const u8 {
    return &stats.pbi_comm;
}

pub fn get_memory(stats: *const libc.proc_taskinfo) u64 {
    return stats.pti_resident_size;
}

pub fn get_runtime(stats: *const libc.proc_bsdinfo) Errors!u64 {
    const since_epoch = @as(u64, @intCast(std.time.milliTimestamp())) / std.time.ms_per_s;
    if (since_epoch < 0) {
        return error.FailedToGetProcessRuntime;
    }
    return since_epoch - stats.pbi_start_tvsec;
}

pub fn get_sid(pid: Pid) Errors!Sid {
    const sid = libc.getsid(pid);
    if (sid == -1) {
        // try log.printdebug("get_sid: Macos LIBC error {d}", .{libc.__error().*});
        return error.FailedToGetProcessSid;
    }
    return sid;
}

pub fn get_process_stats(pid: Pid) Errors!libc.proc_bsdinfo {
    var info: libc.proc_bsdinfo = std.mem.zeroes(libc.proc_bsdinfo);
    const res = libc.proc_pidinfo(
        pid, libc.PROC_PIDTBSDINFO, 0, &info, @sizeOf(libc.proc_bsdinfo)
    );
    if (res != @sizeOf(libc.proc_bsdinfo) or info.pbi_status == libc.SZOMB) {
        // try log.printdebug("get_process_stats: Macos LIBC error {d}", .{libc.__error().*});
        return error.ProcessNotExists;
    } else {
        return info;
    }
}

pub fn get_all_process_stats(pid: Pid) Errors!libc.proc_taskallinfo {
    var info: libc.proc_taskallinfo = std.mem.zeroes(libc.proc_taskallinfo);
    const res = libc.proc_pidinfo(
        pid, libc.PROC_PIDTASKALLINFO, 0, &info, @sizeOf(libc.proc_taskallinfo)
    );
    if (res != @sizeOf(libc.proc_taskallinfo) or info.pbsd.pbi_status == libc.SZOMB) {
        // These logs are disabled because there's a whole lot of them
        // try log.printdebug("get_all_process_stats: Macos LIBC error {d}", .{libc.__error().*});
        return error.ProcessNotExists;
    } else {
        return info;
    }
}

pub fn get_task_stats(pid: Pid) Errors!libc.proc_taskinfo {
    var info: libc.proc_taskinfo = std.mem.zeroes(libc.proc_taskinfo);
    const res = libc.proc_pidinfo(
        pid, libc.PROC_PIDTASKINFO, 0, &info, @sizeOf(libc.proc_taskinfo)
    );
    if (res != @sizeOf(libc.proc_taskinfo)) {
        // try log.printdebug("get_task_stats: Macos LIBC error {d}", .{libc.__error().*});
        return error.ProcessNotExists;
    } else {
        return info;
    }
}
