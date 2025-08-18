const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");
const MainFiles = @import("../file.zig").MainFiles;

const t = @import("./index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const Stats = @import("./stats.zig").Stats;
const r = @import("./resources.zig");
const Resources = r.Resources;
const JSON_Resources = r.JSON_Resources;

const env = @import("./env.zig");
const JSON_Env = env.JSON_Env;

const util = @import("../util.zig");
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const Lengths = util.Lengths;

const e = @import("../error.zig");
const Errors = e.Errors;

pub const TaskReadProcess = switch (builtin.os.tag) {
    .linux => @import("../linux/file.zig").TaskReadProcess,
    .macos => @import("../macos/file.zig").TaskReadProcess,
    .windows => @import("../windows/file.zig").TaskReadProcess,
    else => error.InvalidOs
};
pub const ReadProcess = switch (builtin.os.tag) {
    .linux => @import("../linux/file.zig").ReadProcess,
    .macos => @import("../macos/file.zig").ReadProcess,
    .windows => @import("../windows/file.zig").ReadProcess,
    else => error.InvalidOs
};

const LogLineData = struct {
    time: i64,
    message: []const u8,
    pub fn deinit(self: LogLineData) void {
        util.gpa.free(self.message);
    }
};
const LogFileType = enum { StdOut, StdErr };
const Pipe = if (builtin.target.os.tag == .windows)
    ?[2]std.os.windows.HANDLE
else
    ?[2]i32;

pub const Files = struct {
    const Self = @This();

    task_id: TaskId,

    const file_list = .{
        "stdout",
        "stderr",
        "processes.json",
        "stats.json",
        "resources.json",
        "env.json",
    };

    pub fn init(task_id: TaskId) Errors!Self {
        const file = Self {.task_id = task_id};
        return file;
    }

    pub fn clone(self: *Self) Self {
        return Files {
            .task_id = self.task_id
        };
    }

    // Static fns - Don't need to cache files/Dirs
    /// Checks if a task's directory exists. If not, then it creates it.
    /// directory path: .mult/tasks/{here}
    pub fn task_dir_exists(task_id: TaskId) Errors!bool {
        var tasks_dir = try MainFiles.get_or_create_tasks_dir();
        defer tasks_dir.close();
        const task_path = std.fmt.allocPrint(util.gpa, "{d}", .{task_id})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer util.gpa.free(task_path);
        tasks_dir.access(task_path, .{})
            catch return false;
        return true;
    }

    /// Gets task directory path: .mult/tasks/{here}
    pub fn get_task_dir(self: *Self) Errors!std.fs.Dir {
        var tasks_dir = try MainFiles.get_or_create_tasks_dir();
        defer tasks_dir.close();
        const exists = try task_dir_exists(self.task_id);
        if (!exists) {
            return error.TaskNotExists;
        }

        const task_path = std.fmt.allocPrint(util.gpa, "{d}", .{self.task_id})
            catch |err| return e.verbose_error(err, error.TaskNotExists);
        defer util.gpa.free(task_path);
        const dir = tasks_dir.makeOpenPath(task_path, .{})
            catch |err| return e.verbose_error(err, error.TaskNotExists);
        return dir;
    }

    /// Reading a task file may fail because the daemon clears and overwrites what's
    /// in the file and the read may happen while the write is happening
    pub fn read_file(
        self: *Self, comptime T: type
    ) Errors!?T {
        const name = comptime get_file_name_from_type(T);

        const file = try self.get_file(name);
        defer file.close();

        try log.printdebug("Parsing file: {s}", .{name});

        const file_content = file.readToEndAlloc(util.gpa, 8388608) // 8MB
            catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
        defer util.gpa.free(file_content);
        if (file_content.len == 0) {
            return null;
        }

        var json = std.json.parseFromSlice(
            T,
            util.gpa,
            file_content,
            .{}
        ) catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
        defer {
            json.deinit();
        }
        const value: T = try json.value.clone();

        return value;
    }

    fn filename_valid(comptime name: []const u8) bool {
        inline for (file_list) |item| {
            if (std.mem.eql(u8, item, name))
                return true;
        }
        return false;
    }

    /// Do not forget to close this
    pub fn get_file(self: *Self, comptime name: []const u8) Errors!std.fs.File {
        // This is a runtime check which is bad, make this an enum or something
        if (!filename_valid(name)) return error.InvalidFile;
        try log.printdebug("Getting file: {s}", .{name});
        var task_dir = try self.get_task_dir();
        defer task_dir.close();
        const file = task_dir.openFile(name, .{.mode = .read_write})
            catch |err| switch (err) {
                error.FileNotFound => return error.TaskFileNotFound,
                else => return e.verbose_error(err, error.FailedToGetProcess)
            };
        return file;
    }

    pub fn clear_file(self: *Self, comptime T: type) Errors!void {
        const name = comptime get_file_name_from_type(T);
        // This is a runtime check which is bad, make this an enum or something
        if (!filename_valid(name)) return error.InvalidFile;
        const file = try self.get_file(name);
        defer file.close();
        try log.printdebug("Clearing file: {s}", .{name});
        file.setEndPos(0)
            catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
        file.seekTo(0)
            catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    }

    fn get_file_name_from_type(comptime T: type) []const u8 {
        return comptime switch (T) {
            Stats => "stats.json",
            ReadProcess => "processes.json",
            JSON_Resources => "resources.json",
            JSON_Env => "env.json",
            else => return error.TaskFileFailedRead
        };
    }

    pub fn write_file(
        self: *Self,
        comptime T: type,
        raw_data: T
    ) Errors!void {
        const name = comptime get_file_name_from_type(T);

        try log.printdebug("Writing task {s} file", .{name});

        try self.clear_file(T);

        const file = try self.get_file(name);
        defer file.close();
        var data = if (@hasDecl(T, "to_json"))
                try raw_data.to_json()
            else
                try raw_data.clone();
        defer data.deinit();
        std.json.stringify(data, .{}, file.writer())
            catch |err| return e.verbose_error(err, error.MainFileFailedWrite);
    }

    pub fn delete_files(self: *Self) Errors!void {
        var tasks_dir = try MainFiles.get_or_create_tasks_dir();
        defer tasks_dir.close();

        const string_task_id = std.fmt.allocPrint(util.gpa, "{d}", .{self.task_id})
            catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
        defer util.gpa.free(string_task_id);

        tasks_dir.deleteTree(string_task_id)
            catch |err| return e.verbose_error(err, error.FailedToDeleteTask);
    }

    /// My attempt at reading the last lines of logs without storing them
    /// all in memory, first time doing this so sorry. All it does is goes
    /// through the log files (stdout, stderr), finds the file position at the number of lines
    /// from the end, loops over each one, comparing dates to combine them into
    /// one logs array, goes to the file position again of the number of lines from the end
    /// of each number of occurrences it exists in the last x lines and then reads
    /// those in order. Very messy I wrote it because I wanted the challenge
    pub fn read_last_logs(self: *Self, line_count: u32) Errors!void {
        var outfile = try self.get_file("stdout");
        defer outfile.close();
        var errfile = try self.get_file("stderr");
        defer errfile.close();

        const out_pos = try get_log_position(&outfile, line_count);
        const err_pos = try get_log_position(&errfile, line_count);

        outfile.seekTo(out_pos)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        errfile.seekTo(err_pos)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

        var log_order = std.ArrayList(LogFileType).init(util.gpa);
        defer log_order.deinit();

        // This bit creates a list of either stdout or stderr logs in time order
        var out_line: ?[]const u8 = null;
        var err_line: ?[]const u8 = null;
        // Setting to null to ask to read a new line or keep the existing line
        // in cache
        for (0..(line_count * 2)) |_| {
            if (out_line == null) {
                out_line = try get_log_line(&outfile);
            }
            if (err_line == null) {
                err_line = try get_log_line(&errfile);
            }
            if (
                (out_line == null and err_line == null)
            ) {
                break;
            }
            if (out_line == null) {
                log_order.append(.StdErr)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                util.gpa.free(err_line.?);
                err_line = null;
                continue;
            }
            if (err_line == null) {
                log_order.append(.StdOut)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                util.gpa.free(out_line.?);
                out_line = null;
                continue;
            }
            const out_data = try get_data_from_line(out_line.?);
            const err_data = try get_data_from_line(err_line.?);
            if (out_data.time < err_data.time) {
                log_order.append(.StdOut)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

                util.gpa.free(out_line.?);
                out_data.deinit();

                out_line = null;
            } else {
                log_order.append(.StdErr)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

                util.gpa.free(err_line.?);
                err_data.deinit();

                err_line = null;
            }
        }
        var last_logs = if (line_count > log_order.items.len)
            log_order.items
        else
            log_order.items[(log_order.items.len - line_count)..];
        const out_occurrences = util.count_occurrences(LogFileType, &last_logs, .StdOut);
        const err_occurrences = util.count_occurrences(LogFileType, &last_logs, .StdErr);

        // Resetting log positions to correct
        const new_out_pos = try get_log_position(&outfile, out_occurrences);
        outfile.seekTo(new_out_pos)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        const new_err_pos = try get_log_position(&errfile, err_occurrences);
        errfile.seekTo(new_err_pos)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

        for (last_logs) |log_type| {
            const line = if (log_type == .StdOut)
                try get_log_line(&outfile)
            else
                try get_log_line(&errfile);
            if (line == null) break;
            defer util.gpa.free(line.?);
            const data = try get_data_from_line(line.?);
            defer data.deinit();
            if (log_type == .StdOut) {
                try log.printstdout("{s}", .{data.message});
            } else {
                try log.printstderr("{s}", .{data.message});
            }

        }
    }

    fn get_data_from_line(line: []const u8) Errors!LogLineData {
        var time: [Lengths.TINY]u8 = std.mem.zeroes([Lengths.TINY]u8);
        var line_data = LogLineData {.time = 0, .message = ""};
        for (line, 0..) |char, i| {
            if (std.ascii.isDigit(char)) {
                time[i] = char;
            } else if (char == '|') {
                line_data.time = std.fmt.parseInt(
                    i64, std.mem.trimRight(u8, &time, &[1]u8{0}), 10
                ) catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                line_data.message = try util.strdup(line[(i + 1)..], error.TaskLogsFailedToRead);
                break;
            } else {
                line_data.message = try util.strdup(line, error.TaskLogsFailedToRead);
                break;
            }
        }
        return line_data;
    }

    fn get_log_line(log_file: *std.fs.File) Errors!?[]u8 {
        var line = std.ArrayList(u8).init(util.gpa);
        defer line.deinit();
        const end_pos = log_file.getEndPos()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        const curr_pos = log_file.getPos()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        if (end_pos == 0 or end_pos == curr_pos) return null;

        const reader = log_file.reader();
        while (true) {
            const byte = reader.readByte()
                catch |err| return switch (err) {
                    error.EndOfStream => break,
                    else => e.verbose_error(err, error.TaskLogsFailedToRead)
                };
            if (byte == '\n') {
                line.append(byte)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                break;
            } else {
                line.append(byte)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            }
        }
        return line.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
    }

    fn get_log_position(log_file: *std.fs.File, line_count: u32) Errors!u64 {
        log_file.seekFromEnd(0)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        const end_pos = log_file.getEndPos()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        if (end_pos == 0) return 0;

        const reader = log_file.reader();
        var line_counter: u64 = 0;
        while (true) {
            if (line_counter == line_count) {
                break;
            }
            log_file.seekBy(-2)
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            const prev_byte = reader.readByte()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            if (prev_byte == '\n') {
                line_counter += 1;
            }
            const curr_pos = log_file.getPos()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            if (curr_pos == 1) {
                return 0;
            }
        }
        const pos = log_file.getPos()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        return pos;
    }

    /// Seek to end of files, and look for any changes to the files by seeing
    /// if the end pos increases. If it does, print out whatever's there by line
    pub fn listen_log_files(self: *Self) Errors!void {
        const outfile = try self.get_file("stdout");
        defer outfile.close();
        const errfile = try self.get_file("stderr");
        defer errfile.close();
        outfile.seekFromEnd(0)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        errfile.seekFromEnd(0)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        const out_reader = outfile.reader();
        const err_reader = errfile.reader();
        var out_end_pos = outfile.getEndPos()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        var err_end_pos = errfile.getEndPos()
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        var out_line = std.ArrayList(u8).init(util.gpa);
        defer out_line.deinit();
        var err_line = std.ArrayList(u8).init(util.gpa);
        defer err_line.deinit();

        var out_lines = std.ArrayList(LogLineData).init(util.gpa);
        defer out_lines.deinit();
        var err_lines = std.ArrayList(LogLineData).init(util.gpa);
        defer err_lines.deinit();

        while (true) {
            outfile.sync()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            errfile.sync()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            const new_out_end_pos = outfile.getEndPos()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            const new_err_end_pos = errfile.getEndPos()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

            // Stdout
            if (new_out_end_pos > out_end_pos) {
                while (true) {
                    const byte = out_reader.readByte()
                        catch |err| switch (err) {
                            error.EndOfStream => break,
                            else => return e.verbose_error(err, error.TaskLogsFailedToRead)
                        };
                    out_line.append(byte)
                        catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                    if (byte == '\n' and out_line.items.len > 0) {
                        const line_data = try get_data_from_line(out_line.items);
                        out_lines.append(line_data)
                            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                        out_end_pos = outfile.getEndPos()
                            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                        out_line.clearAndFree();
                    }
                }
                if (out_line.items.len > 0 and out_line.items[out_line.items.len - 1] != '\n') {
                    const line_data = try get_data_from_line(out_line.items);
                    out_lines.append(line_data)
                        catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                    out_end_pos = outfile.getEndPos()
                        catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                    out_line.clearAndFree();
                }
            }

            // Stderr
            if (new_err_end_pos > err_end_pos) {
                while (true) {
                    const byte = err_reader.readByte()
                        catch |err| switch (err) {
                            error.EndOfStream => break,
                            else => return e.verbose_error(err, error.TaskLogsFailedToRead)
                        };
                    err_line.append(byte)
                        catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                    if (byte == '\n' and err_line.items.len > 0) {
                        const line_data = try get_data_from_line(err_line.items);
                        err_lines.append(line_data)
                            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                        err_end_pos = errfile.getEndPos()
                            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                        err_line.clearAndFree();
                    }
                }
                if (err_line.items.len > 0 and err_line.items[err_line.items.len - 1] != '\n') {
                    const line_data = try get_data_from_line(err_line.items);
                    err_lines.append(line_data)
                        catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                    err_end_pos = errfile.getEndPos()
                        catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                    err_line.clearAndFree();
                }
            }


            // Iterating over each log seeing which should be printed based
            // on time
            if (err_lines.items.len == 0) {
                for (out_lines.items) |item| {
                    try log.printstdout("{s}", .{item.message});
                }
            } else if (out_lines.items.len == 0) {
                for (err_lines.items) |item| {
                    try log.printstderr("{s}", .{item.message});
                }
            } else {
                var out_idx: usize = 0;
                var err_idx: usize = 0;
                for (0..(err_lines.items.len + out_lines.items.len)) |_| {
                    if (err_idx >= err_lines.items.len) {
                        if (out_idx >= out_lines.items.len) break;
                        try log.printstdout("{s}", .{out_lines.items[out_idx].message});
                        out_idx += 1;
                        continue;
                    }
                    if (out_idx >= out_lines.items.len) {
                        if (err_idx >= err_lines.items.len) break;
                        try log.printstderr("{s}", .{err_lines.items[err_idx].message});
                        err_idx += 1;
                        continue;
                    }
                    const out = out_lines.items[out_idx];
                    const err = err_lines.items[err_idx];
                    if (out.time < err.time) {
                        try log.printstdout("{s}", .{out.message});
                        out_idx += 1;
                    } else if (err.time < out.time) {
                        try log.printstderr("{s}", .{err.message});
                        err_idx += 1;
                    } else if (err.time == out.time) {
                        try log.printstderr("{s}", .{err.message});
                        try log.printstdout("{s}", .{out.message});
                        out_idx += 1;
                        err_idx += 1;
                    }
                }
            }
            out_lines.clearAndFree();
            err_lines.clearAndFree();

            std.time.sleep(100000); // 100ms
        }
    }
};
