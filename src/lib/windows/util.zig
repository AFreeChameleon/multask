const libc = @import("../c.zig").libc;
const std = @import("std");

pub fn combine_filetime(ft: *libc.FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

pub fn convert_filetime64_to_unix_epoch(ft64: u64) u64 {
    return (ft64 / 10000000) - 11644473600;
}

pub fn can_breakaway() bool {
    var in_job: libc.BOOL = 0;
    if (libc.IsProcessInJob(libc.GetCurrentProcess(), null, &in_job) == 0)
        return false;
    if (in_job == 0)
        return true; // not in a job → can break away

    // Check job limits
    // const info_class = libc.JOB_OBJECT_LIMIT_FLAGS;
    var info: libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroInit(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION, .{});
    var ret_len: libc.DWORD = 0;
    const ok = libc.QueryInformationJobObject(
        null,
        libc.JobObjectExtendedLimitInformation,
        &info,
        @sizeOf(libc.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        &ret_len,
    );
    if (ok == 0)
        return false;

    const flags = info.BasicLimitInformation.LimitFlags;
    const has_breakaway = (flags & libc.JOB_OBJECT_LIMIT_BREAKAWAY_OK) != 0 or
                          (flags & libc.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) != 0;

    return has_breakaway;
}
