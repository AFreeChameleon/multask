const libc = @import("../c.zig").libc;

pub fn combine_filetime(ft: *libc.FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

pub fn convert_filetime64_to_unix_epoch(ft64: u64) u64 {
    return (ft64 / 10000000) - 11644473600;
}