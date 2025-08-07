const builtin = @import("builtin");
const std = @import("std");
const e = @import("./error.zig");
const util = @import("./util.zig");
const Lengths = util.Lengths;
const file = @import("./file.zig");

pub var debug = false;
pub var is_forked = false;

pub var stdout_file: std.fs.File = undefined;

pub fn init() e.Errors!void {
    if (comptime builtin.target.os.tag == .windows) {
        const win_log = @import("./windows/log.zig");
        try win_log.enable_virtual_terminal();
    }
    stdout_file = std.io.getStdOut();
}

pub fn print(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = stdout_file.writer();
    stdout.print(text, args) catch {
        return error.InternalLoggingFailed;
    };
}

pub fn printsucc(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = stdout_file.writer();
    const success_str = try util.colour_string(
        "[SUCCESS]", 0, 204, 102
    );
    defer util.gpa.free(success_str);
    if (!builtin.is_test) {
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
    const colour_str = try util.colour_string(
        "[DEBUG]", 243, 0, 255
    );
    defer util.gpa.free(colour_str);
    const content = std.fmt.allocPrint(util.gpa, " " ++ text ++ "\n", args)
        catch return error.InternalLoggingFailed;
    defer util.gpa.free(content);
    const line = std.fmt.allocPrint(util.gpa, "{s} {s}", .{colour_str, content})
        catch return error.InternalLoggingFailed;
    defer util.gpa.free(line);
    if (debug) {
        write_to_debug_log_file(line)
            catch return error.InternalLoggingFailed;
    }
    if (debug and !is_forked and !builtin.is_test) {
        const stdout = stdout_file.writer();
        stdout.print("{s}", .{colour_str})
            catch return error.InternalLoggingFailed;
        stdout.print(" " ++ text ++ "\n", args)
            catch return error.InternalLoggingFailed;
    }
}

pub fn printinfo(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = stdout_file.writer();
    const colour_str = try util.colour_string(
        "[INFO]", 0, 51, 255
    );
    defer util.gpa.free(colour_str);
    if (!builtin.is_test) {
        stdout.print("{s}", .{colour_str})
            catch return error.InternalLoggingFailed;
        stdout.print(" " ++ text ++ "\n", args)
            catch return error.InternalLoggingFailed;
    }
}

pub fn printwarn(comptime text: []const u8, args: anytype) e.Errors!void {
    const stdout = stdout_file.writer();
    const colour_str = try util.colour_string(
        "[WARNING]", 204, 102, 0
    );
    stdout.print("{s}", .{colour_str})
        catch return error.InternalLoggingFailed;
    stdout.print(" " ++ text ++ "\n", args)
        catch return error.InternalLoggingFailed;
}

pub fn print_custom_err(comptime text: []const u8, args: anytype) e.Errors!void {
    const stderr = std.io.getStdErr().writer();
    const colour_str = try util.colour_string(
        "[ERROR]", 204, 0, 0
    );
    defer util.gpa.free(colour_str);
    stderr.print("{s}", .{colour_str})
        catch return error.InternalLoggingFailed;
    stderr.print(text ++ "\n", args)
        catch return error.InternalLoggingFailed;
}

pub fn printstdout(comptime text: []const u8, args: anytype) e.Errors!void {
    if (text.len == 0) return;
    const stdout = stdout_file.writer();
    const colour_str = try util.colour_string(
        "[STDOUT]", 0, 255, 255
    );
    defer util.gpa.free(colour_str);
    stdout.print("{s}", .{colour_str})
        catch return error.InternalLoggingFailed;
    stdout.print(" " ++ text, args)
        catch return error.InternalLoggingFailed;
}

pub fn printstderr(comptime text: []const u8, args: anytype) e.Errors!void {
    if (text.len == 0) return;
    const stdout = stdout_file.writer();
    const colour_str = try util.colour_string(
        "[STDERR]", 204, 0, 0
    );
    stdout.print("{s}", .{colour_str})
        catch return error.InternalLoggingFailed;
    stdout.print(" " ++ text, args)
        catch return error.InternalLoggingFailed;
}

pub fn printerr(e_type: e.Errors) e.Errors!void {
    const stderr = std.io.getStdErr().writer();
    const message = try e.get_error_msg(e_type);
    stderr.print("\x1B[38;2;204;0;0m[ERROR]\x1B[0m {s}\n", .{message})
        catch return error.InternalLoggingFailed;
}

pub fn print_help(comptime rows: anytype) e.Errors!void {
    inline for (rows) |row| {
        inline for (row, 0..) |col, i| {
            try print("{s}", .{col});
            if (row.len - 1 == i) {
                try print("\n", .{});
            } else {
                try print("\t", .{});
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
