const libc = @import("../c.zig").libc;
const std = @import("std");
const e = @import("../error.zig");
const log = @import("../log.zig");
const Errors = e.Errors;

pub fn enable_virtual_terminal() Errors!void {
    _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    const handle = libc.GetStdHandle(libc.STD_OUTPUT_HANDLE);
    var original_mode: c_int = 0;
    if (libc.GetConsoleMode(handle, @ptrCast(&original_mode)) == 0) {
        try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
        return error.InvalidShell;
    }

    const enabled = original_mode & libc.ENABLE_VIRTUAL_TERMINAL_PROCESSING
        == libc.ENABLE_VIRTUAL_TERMINAL_PROCESSING;

    if (!enabled) {
        if (libc.SetConsoleMode(handle, @as(c_ulong, @intCast(libc.ENABLE_VIRTUAL_TERMINAL_PROCESSING ^ original_mode))) == 0) {
            try log.printdebug("Windows error code: {d}", .{std.os.windows.GetLastError()});
            return error.InvalidShell;
        }
    }
}