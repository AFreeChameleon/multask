const libc = @import("../c.zig").libc;
const std = @import("std");

// 1 second in ns
pub const TIME_INTERVAL: f64 = 1E+9;

pub fn calc_nanosenconds_per_mach_tick() u32 {
    var info: libc.mach_timebase_info_data_t =
        std.mem.zeroes(libc.mach_timebase_info_data_t);
    _ = libc.mach_timebase_info(&info);
    return info.numer / info.denom;
}

pub fn mach_ticks_to_nanoseconds(time: u64) u64 {
    return time * calc_nanosenconds_per_mach_tick();
}
