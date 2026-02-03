const builtin = @import("builtin");
const std = @import("std");
const flute = @import("flute");
const e = @import("./error.zig");
const util = @import("./util.zig");
const file = @import("./file.zig");

pub var debug = false;
pub var enabled_logging = true;
pub var is_forked = false;

pub fn init() e.Errors!void {
    if (enabled_logging) {
        if (comptime builtin.target.os.tag == .windows) {
            const win_log = @import("./windows/log.zig");
            try win_log.enable_virtual_terminal();
        }
    }
}

pub fn printsucc(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = std.io.getStdOut().writer();
    const success_str = flute.format.string.colorStringComptime(.{0, 204, 102}, "[SUCCESS]");
    if (!builtin.is_test and enabled_logging) {
        stdout.print("{s}", .{success_str})
            catch return error.InternalLoggingFailed;
        stdout.print(" " ++ text ++ "\n", args)
            catch return error.InternalLoggingFailed;
    }
}

pub fn enable_debug() void {
    debug = true;
}
pub fn printdebug(comptime text: []const u8, args: anytype) e.Errors!void {
    if (debug) {
        const colour_str = flute.format.string.colorStringComptime(.{243, 0, 255}, "[DEBUG]");
        const content = std.fmt.allocPrint(util.gpa, " " ++ text ++ "\n", args)
            catch return error.InternalLoggingFailed;
        defer util.gpa.free(content);
        const line = std.fmt.allocPrint(util.gpa, "{s} {s}", .{colour_str, content})
            catch return error.InternalLoggingFailed;
        defer util.gpa.free(line);

        write_to_debug_log_file(line)
            catch return error.InternalLoggingFailed;

        if (!is_forked and !builtin.is_test and enabled_logging) {
            const stdout = std.io.getStdOut().writer();
            stdout.print("{s}", .{colour_str})
                catch return error.InternalLoggingFailed;
            stdout.print(" " ++ text ++ "\n", args)
                catch return error.InternalLoggingFailed;
        }
    }
}

pub fn print(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(text, args)
        catch return error.InternalLoggingFailed;
}

pub fn println(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(text ++ "\n", args)
        catch return error.InternalLoggingFailed;
}

pub fn printinfo(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = std.io.getStdOut().writer();
    const colour_str = flute.format.string.colorStringComptime(.{0, 51, 255}, "[INFO]");
    if (!builtin.is_test and enabled_logging) {
        stdout.print("{s}", .{colour_str})
            catch return error.InternalLoggingFailed;
        stdout.print(" " ++ text ++ "\n", args)
            catch return error.InternalLoggingFailed;
    }
}

pub fn printwarn(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = std.io.getStdOut().writer();
    const colour_str = flute.format.string.colorStringComptime(.{204, 102, 0}, "[WARNING]");
    if (enabled_logging) {
        stdout.print("{s}", .{colour_str})
            catch return error.InternalLoggingFailed;
        stdout.print(" " ++ text ++ "\n", args)
            catch return error.InternalLoggingFailed;
    }
}

pub fn print_custom_err(comptime text: []const u8, args: anytype) e.Errors!void {
    const stderr = std.io.getStdErr().writer();
    const colour_str = flute.format.string.colorStringComptime(.{204, 0, 0}, "[ERROR]");
    stderr.print("{s}", .{colour_str})
        catch return error.InternalLoggingFailed;
    stderr.print(text ++ "\n", args)
        catch return error.InternalLoggingFailed;
}

pub fn printstdout(comptime text: []const u8, args: anytype) e.Errors!void {
    if (text.len == 0) return;
    const stdout = std.io.getStdOut().writer();
    const colour_str = flute.format.string.colorStringComptime(.{0, 255, 255}, "[STDOUT]");
    stdout.print("{s}", .{colour_str})
        catch return error.InternalLoggingFailed;
    stdout.print(" " ++ text, args)
        catch return error.InternalLoggingFailed;
}

pub fn printstderr(comptime text: []const u8, args: anytype) e.Errors!void {
    if (text.len == 0) return;
    const stdout = std.io.getStdOut().writer();
    const colour_str = flute.format.string.colorStringComptime(.{204, 0, 0}, "[STDERR]");
    if (enabled_logging) {
        stdout.print("{s}", .{colour_str})
            catch return error.InternalLoggingFailed;
        stdout.print(" " ++ text, args)
            catch return error.InternalLoggingFailed;
    }
}

pub fn printerr(e_type: e.Errors) e.Errors!void {
    var fbs_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&fbs_buf);

    var buf = std.io.bufferedWriter(fbs.writer());
    var stderr = buf.writer();

    const message = try e.get_error_msg(e_type);
    var error_prefix: []const u8 = "[ERROR]";
    if (enabled_logging) {
        error_prefix = flute.format.string.colorStringComptime(.{204, 0, 0}, "[ERROR]");
    }
    _ = stderr.write(error_prefix)
        catch return error.InternalLoggingFailed;
    _ = stderr.writeByte(' ')
        catch return error.InternalLoggingFailed;
    stderr.print("{s}\n", .{message})
        catch return error.InternalLoggingFailed;

    if (debug) {
        buf.flush()
            catch return error.InternalLoggingFailed;
        const content = fbs.getWritten();
        if (builtin.target.os.tag == .windows) {
            stderr.print("OS Error code: {d}\n", .{std.os.windows.GetLastError()})
                catch return error.InternalLoggingFailed;
        } else {
            stderr.print("OS Error code: {d}\n", .{std.c._errno().*})
                catch return error.InternalLoggingFailed;
        }
        write_to_debug_log_file(content)
            catch return error.InternalLoggingFailed;
    }
    
    if (enabled_logging) {
        buf.flush()
            catch return error.InternalLoggingFailed;
        const content = fbs.getWritten();
        const stderr_writer = std.io.getStdErr().writer();
        _ = stderr_writer.write(content)
            catch return error.InternalLoggingFailed;
    }
}

pub fn print_help(comptime rows: anytype) e.Errors!void {
    const stdout = std.io.getStdOut().writer();
    var buf = std.io.bufferedWriter(stdout);
    var w = buf.writer();

    try print_help_buf(rows, &w);
    buf.flush() catch return error.InternalLoggingFailed;
}

pub fn print_help_buf(comptime rows: anytype, writer: anytype) e.Errors!void {
    inline for (rows) |row| {
        inline for (row, 0..) |col, i| {
            writer.print("{s}", .{col}) catch return error.InternalLoggingFailed;
            if (row.len - 1 == i) {
                writer.print("\n", .{}) catch return error.InternalLoggingFailed;
            } else {
                writer.print("\t", .{}) catch return error.InternalLoggingFailed;
            }
        }
    }
}

/// Writes any debug statement to the log file
fn write_to_debug_log_file(text: []const u8) e.Errors!void {
    const log_file = try file.MainFiles.get_debug_log_file();
    defer log_file.close();
    const endPos = log_file.getEndPos()
        catch return error.DebugLogFileFailedWrite;
    log_file.seekTo(endPos)
        catch return error.DebugLogFileFailedWrite;
    const timestamped = std.fmt.allocPrint(
        util.gpa,
        "{d}: {s}",
        .{std.time.timestamp(), text}
    ) catch return error.DebugLogFileFailedWrite;
    defer util.gpa.free(timestamped);
    log_file.writeAll(text)
        catch return error.DebugLogFileFailedWrite;
}
