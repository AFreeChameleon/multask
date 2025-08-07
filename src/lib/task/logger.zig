const std = @import("std");
const util = @import("../util.zig");

const e = @import("../error.zig");
const Errors = e.Errors;

pub fn write_start_time(
    comptime T: type,
    outwriter: *T,
    errwriter: *T
) Errors!void {
    const epoch = std.time.microTimestamp();
    const str_epoch_sep = std.fmt.allocPrint(util.gpa, "{d}|", .{epoch})
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    defer util.gpa.free(str_epoch_sep);
    _ = outwriter.write(str_epoch_sep)
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    _ = errwriter.write(str_epoch_sep)
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    outwriter.flush()
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    errwriter.flush()
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
}

pub fn write_timed_logs(
    new_line: *bool,
    buf: []u8,
    comptime T: type,
    writer: *T
) Errors!void {
    // Loop over each character, if it's a \n write it and then print the timestamp
    if (buf.len > 0) {
        var line = std.ArrayList(u8).init(util.gpa);
        defer line.deinit();
        const end_with_new_line = buf[buf.len - 1] == '\n';
        for (buf) |char| {
            if (new_line.*) {
                const epoch = std.time.microTimestamp();
                const str_epoch_sep = std.fmt.allocPrint(util.gpa, "{d}|", .{epoch})
                    catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
                defer util.gpa.free(str_epoch_sep);
                line.appendSlice(str_epoch_sep)
                    catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
                new_line.* = false;
            }
            if (char == '\n') {
                new_line.* = true;
            }
            line.append(char)
                catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
        }
        if (!end_with_new_line) {
            line.append('\n')
                catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
        }
        _ = writer.write(line.items)
            catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    }
    writer.flush()
        catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
}

