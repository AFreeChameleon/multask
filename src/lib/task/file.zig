const std = @import("std");
const builtin = @import("builtin");
const flute = @import("flute");
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

const e = @import("../error.zig");
const Errors = e.Errors;

pub const LogFileListener = switch (builtin.os.tag) {
    .linux => @import("../linux/file.zig").LogFileListener,
    .macos => @import("../macos/file.zig").LogFileListener,
    .windows => @import("../windows/file.zig").LogFileListener,
    else => error.InvalidOs
};

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

pub const StdLogFileEvent = enum {
    out,
    err,
    skip
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

pub fn OutputPadding(comptime text: []const u8, comptime rgb: [3]u8) usize {
    const padding = flute.format.string.ColorStringWidthPadding(rgb);
    return padding + text.len;
}
pub const StdoutPadding = OutputPadding("[STDOUT] ", .{0, 255, 255});
pub const StderrPadding = OutputPadding("[STDERR] ", .{204, 0, 0});

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
        var buf: [32]u8 = undefined;
        const task_path = std.fmt.bufPrint(&buf, "{d}", .{task_id})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        tasks_dir.access(task_path, .{})
            catch return false;
        return true;
    }

    /// Gets task directory path: .mult/tasks/{here}
    pub fn get_task_dir(self: *Self) Errors!std.fs.Dir {
        var tasks_dir = try MainFiles.get_or_create_tasks_dir();
        defer tasks_dir.close();

        var buf: [32]u8 = undefined;
        const task_path = std.fmt.bufPrint(&buf, "{d}", .{self.task_id})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
    
        const dir = tasks_dir.openDir(task_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return tasks_dir.makeOpenPath(task_path, .{})
                    catch |inner_err| return e.verbose_error(inner_err, error.TaskNotExists);
            },
            else => return error.TaskNotExists
        };

        return dir;
    }

    /// Reading a task file may fail because the daemon clears and overwrites what's
    /// in the file and the read may happen while the write is happening
    pub fn read_file(
        self: *Self, comptime T: type
    ) Errors!?T {
        const name = comptime get_file_name_from_type(T);

        const file = try self.get_file(name);
        file.lock(.exclusive)
            catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
        defer {
            file.unlock();
            file.close();
        }

        try log.printdebug("Parsing file: {s}", .{name});

        const buf_len = 100_000; // 100 kb
        var buf: [buf_len]u8 = undefined;
        const written = file.readAll(&buf)
            catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
        if (written == 0 or written > buf_len) {
            return null;
        }
        const file_content = buf[0..written];

        var json = std.json.parseFromSlice(
            T,
            util.gpa,
            file_content,
            .{}
        ) catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
        defer json.deinit();
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

    /// Do not forget to unlock & close this
    pub fn get_file_locked(self: *Self, comptime T: type) Errors!std.fs.File {
        // This is a runtime check which is bad, make this an enum or something
        const name = comptime get_file_name_from_type(T);
        try log.printdebug("Getting file: {s}", .{name});
        var task_dir = try self.get_task_dir();
        defer task_dir.close();
        const file = task_dir.openFile(name, .{.mode = .read_write})
            catch |err| switch (err) {
                error.FileNotFound => return error.TaskFileNotFound,
                else => return e.verbose_error(err, error.FailedToGetProcess)
            };
        file.lock(.exclusive)
            catch |err| return e.verbose_error(err, error.TaskFileNotFound);
        return file;
    }

    /// Do not forget to lock & close this
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

    /// The file should already be locked so it does not lock it
    pub fn clear_file(file: *const std.fs.File) Errors!void {
        try log.printdebug("Clearing file", .{});
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
        file: *const std.fs.File,
        comptime T: type,
        raw_data: T
    ) Errors!void {
        try clear_file(file);
        var buf_writer = std.io.bufferedWriter(file.writer());

        var data = if (@hasDecl(T, "to_json"))
                try raw_data.to_json()
            else
                try raw_data.clone();
        defer data.deinit();
        std.json.stringify(data, .{}, buf_writer.writer())
            catch |err| return e.verbose_error(err, error.MainFileFailedWrite);
        buf_writer.flush()
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
        var time: [32]u8 = std.mem.zeroes([32]u8);
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




    pub fn listen_log_files(self: *Self) Errors!void {
        const outfile = try self.get_file("stdout");
        defer outfile.close();
        const errfile = try self.get_file("stderr");
        defer errfile.close();
        outfile.seekFromEnd(0)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        errfile.seekFromEnd(0)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

        var err_buf_reader = std.io.bufferedReader(errfile.reader());
        var out_buf_reader = std.io.bufferedReader(outfile.reader());
        const err_reader = err_buf_reader.reader();
        const out_reader = out_buf_reader.reader();

        var stdout_log_prefix_buf: [StdoutPadding]u8 = std.mem.zeroes([StdoutPadding]u8);
        var stderr_log_prefix_buf: [StderrPadding]u8 = std.mem.zeroes([StderrPadding]u8);
        const stdout_log_prefix = flute.format.string.colorStringBuf(&stdout_log_prefix_buf, "[STDOUT] ", 0, 255, 255)
            catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        const stderr_log_prefix = flute.format.string.colorStringBuf(&stderr_log_prefix_buf, "[STDERR] ", 204, 0, 0)
           catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);

        const stdout = std.io.getStdOut();
        const stderr = std.io.getStdErr();
        var out_buf = std.io.bufferedWriter(stdout.writer());
        var err_buf = std.io.bufferedWriter(stderr.writer());
        const out_wr = out_buf.writer();
        const err_wr = err_buf.writer();

        var listener = try LogFileListener.setup(self.task_id, LogFileListener.MainIO);

        // Buffer length & length of max value of i64
        var new_content_buf: [4096 + 19]u8 = std.mem.zeroes([4096 + 19]u8);
        while (
            try listener.read(LogFileListener.MainIO)
        ) |file_written| {
            if (file_written == .skip) continue;
            var log_prefix: @TypeOf(stdout_log_prefix) = undefined;
            var wr: *const @TypeOf(out_wr) = undefined;
            var reader: *const @TypeOf(out_reader) = undefined;
            var log_buf: *@TypeOf(out_buf) = undefined;
            if (file_written == .out) {
                log_prefix = stdout_log_prefix;
                reader = &out_reader;
                wr = &out_wr;
                log_buf = &out_buf;
            } else if (file_written == .err) {
                log_prefix = stderr_log_prefix;
                wr = &err_wr;
                reader = &err_reader;
                log_buf = &err_buf;
            }
            while (true) {
                new_content_buf = std.mem.zeroes(@TypeOf(new_content_buf));
                _ = reader.readUntilDelimiterOrEof(&new_content_buf, '\n')
                    catch |err| switch (err) {
                        error.StreamTooLong => {},
                        else => return e.verbose_error(err, error.TaskLogsFailedToRead)
                    };

                const new_content = std.mem.trimRight(u8, &new_content_buf, &[2]u8{'\n', 0});
                if (new_content.len == 0) {
                    break;
                }
                var pipe_idx = std.mem.indexOfScalar(u8, new_content, '|');
                if (pipe_idx == null) {
                    pipe_idx = 0;
                } else {
                    // Add extra for the |
                    pipe_idx.? += 1;
                }
                _ = wr.write(log_prefix)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                _ = wr.write(new_content[pipe_idx.?..])
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                wr.writeByte('\n')
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
            }
            log_buf.flush()
                catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
        }
        try listener.close(LogFileListener.MainIO);
    }

    pub fn save_stats(task: *t.Task, flags: *const util.ForkFlags) Errors!void {
        try util.validate_flags(.{
            .memory_limit = flags.memory_limit,
            .cpu_limit = flags.cpu_limit
        });

        // Have to refresh stats
        if (flags.cpu_limit != null) {
            task.stats.?.cpu_limit = flags.cpu_limit.?;
        }
        if (flags.memory_limit != null) {
            task.stats.?.memory_limit = flags.memory_limit.?;
        }
        if (flags.persist != null) {
            task.stats.?.persist = flags.persist.?;
        }
        if (flags.interactive != null) {
            task.stats.?.interactive = flags.interactive.?;
        }

        const file = try task.files.?.get_file_locked(Stats);
        defer {
            file.unlock();
            file.close();
        }

        var stats_clone = try task.stats.?.clone();
        defer stats_clone.deinit();
        try Files.write_file(&file, Stats, stats_clone);
    }

};
