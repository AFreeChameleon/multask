const std = @import("std");
const util = @import("../util.zig");

const e = @import("../error.zig");
const Errors = e.Errors;

pub const LOG_BUF_SIZE = 4096;

// Max val of an i64 is 9223372036854775807
const I64_MAX_STR_LEN = 19;

pub fn write_timestamp(
    comptime T: type,
    writer: *T,
) Errors!void {
    const epoch = std.time.microTimestamp();
    var epoch_buf: [I64_MAX_STR_LEN + 1]u8 = std.mem.zeroes([I64_MAX_STR_LEN + 1]u8);
    const epoch_slice = std.fmt.bufPrint(&epoch_buf, "{d}|", .{epoch})
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    _ = writer.write(epoch_slice)
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    writer.flush()
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
}

pub fn write_timed_logs(
    new_line: bool,
    buf: []u8,
    comptime T: type,
    writer: *T
) Errors!bool {
    const end_with_new_line = buf[buf.len - 1] == '\n';
    if (new_line) {
        write_timestamp(T, writer)
            catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    }
    _ = writer.write(buf)
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    writer.flush()
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    return end_with_new_line;
}
