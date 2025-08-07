const builtin = @import("builtin");
const std = @import("std");

const libc = @import("./c.zig").libc;
const e = @import("./error.zig");
const Errors = e.Errors;

const util = @import("./util.zig");
const log = @import("./log.zig");

/// Sets the cols to whatever columns the window has
pub fn get_window_cols() Errors!u32 {
    var cols: u32 = 0;
    if (comptime builtin.target.os.tag != .windows) {
        var w: libc.winsize = undefined;
        _ = libc.ioctl(libc.STDOUT_FILENO, libc.TIOCGWINSZ, &w);
        cols = w.ws_col;
    } else {
        var csbi: libc.CONSOLE_SCREEN_BUFFER_INFO = std.mem.zeroes(libc.CONSOLE_SCREEN_BUFFER_INFO);
        const res = libc.GetConsoleScreenBufferInfo(libc.GetStdHandle(libc.STD_OUTPUT_HANDLE), &csbi);
        if (res == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.FailedToSetWindowCols;
        }
        cols = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1);
    }
    return cols;
}

