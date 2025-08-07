const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");
const MainFiles = @import("../file.zig").MainFiles;

const t = @import("./index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const Stats = @import("./stats.zig").Stats;

const util = @import("../util.zig");
const Pid = util.Pid;
const Lengths = util.Lengths;

const e = @import("../error.zig");
const Errors = e.Errors;

const ReadProcess = struct {
    pid: Pid,
    starttime: u32,
    children: []ProcessSection
};
const ProcessSection = struct {
    pid: Pid,
    starttime: u32,
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
        "processes",
        "stats",
        "usage",
        "task_pid"
    };

    pub fn init(task_id: TaskId) Errors!Self {
        const file = Self {.task_id = task_id};
        return file;
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

    /// Separates process id from starttime in processes file
    fn separate_process_section(section: []const u8) Errors!ProcessSection {
        var pid_starttime_iter = std.mem.splitAny(u8, section, ":");
        const pid_str = pid_starttime_iter.next();
        if (pid_str == null) {
            return error.FailedToGetProcesses;
        }
        const starttime_str = pid_starttime_iter.next();
        if (starttime_str  == null) {
            return error.FailedToGetProcesses;
        }

        const pid = std.fmt.parseInt(util.Pid, pid_str.?, 10)
            catch |err| return e.verbose_error(
                err, error.FailedToGetProcesses
            );
        const starttime = std.fmt.parseInt(u32, starttime_str.?, 10)
            catch |err| return e.verbose_error(
                err, error.FailedToGetProcesses
            );
        return ProcessSection {
            .pid = pid,
            .starttime = starttime
        };
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

    /// Reads task's processes file.
    /// path: .mult/tasks/task_id/processes
    pub fn read_processes_file(self: *Self) Errors!ReadProcess {
        try log.printdebug("Getting task processes file", .{});
        var bracket_count: i32 = 0;

        var arena = std.heap.ArenaAllocator.init(util.gpa);
        defer arena.deinit();
        var children = std.ArrayList(ProcessSection).init(arena.allocator());
        defer children.deinit();
        var main_pid: util.Pid = 0;
        var main_starttime: u32 = 0;
        const processes_file = try self.get_file("processes");
        defer processes_file.close();

        var buf_reader = std.io.bufferedReader(processes_file.reader());
        var reader = buf_reader.reader();
        var buf: [Lengths.MEDIUM]u8 = std.mem.zeroes([Lengths.MEDIUM]u8);
        var buf_fbs = std.io.fixedBufferStream(&buf);
        while (
            true
        ) {
            // this will get the <pid>:<starttime>
            reader.streamUntilDelimiter(buf_fbs.writer(), ',', buf_fbs.buffer.len)
                catch |err| switch (err) {
                    error.NoSpaceLeft => break,
                    error.EndOfStream => break,
                    else => |inner_err| return e.verbose_error(
                        inner_err, error.FailedToGetProcesses
                    )
                };
            const it = buf_fbs.getWritten();
            defer buf_fbs.reset();
            if (it.len == 0) {
                break;
            }

            const section = try util.strdup(it, error.FailedToGetProcesses);
            defer util.gpa.free(section);
            if (section[0] == '(') {
                bracket_count += 1;
                const proc_section = try separate_process_section(section[1..]);
                children.append(proc_section)
                    catch |err| return e.verbose_error(
                        err, error.FailedToGetProcesses
                    );
                continue;
            }
            if (section[section.len - 1] == ')') {
                bracket_count -= 1;
                continue;
            }
            // Main pid
            if (bracket_count == 0) {
                const proc_section = try separate_process_section(section);
                main_pid = proc_section.pid;
                main_starttime = proc_section.starttime;
            } else {
                const proc_section = try separate_process_section(section);
                children.append(
                    proc_section
                ) catch |err| return e.verbose_error(
                    err, error.FailedToGetProcesses
                );
            }
        }
        processes_file.seekTo(0)
            catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        return ReadProcess {
            .pid = main_pid,
            .starttime = main_starttime,
            .children = util.gpa.dupe(ProcessSection, children.items)
                catch |err| return e.verbose_error(
                    err, error.FailedToGetProcesses
                )
        };
    }


    pub fn read_task_pid_file(self: *Self) Errors!Pid {
        try log.printdebug("Reading task pid file...", .{});
        const task_pid = try self.get_file("task_pid");
        defer task_pid.close();
        const file_stat = task_pid.stat()
            catch |err| return e.verbose_error(err, error.FailedToReadTaskPid);
        if (file_stat.size > Lengths.TINY) {
            try log.printdebug("Pid is too large for buffer", .{});
            return error.FailedToReadTaskPid;
        }

        // All this needs to do is read a pid string into a pid
        const line = task_pid.readToEndAlloc(util.gpa, @intCast(file_stat.size))
            catch |err| return e.verbose_error(err, error.FailedToReadTaskPid);
        defer util.gpa.free(line);

        const pid = std.fmt.parseInt(Pid, line, 10)
            catch |err| return e.verbose_error(err, error.FailedToReadTaskPid);
        task_pid.seekTo(0)
            catch |err| return e.verbose_error(err, error.FailedToReadTaskPid);
        return pid;
    }

    pub fn read_stats_file(self: *Self) Errors!Stats {
        try log.printdebug("Getting task stats file", .{});

        var stats = Stats {
            .cwd = undefined,
            .command = undefined,
            .memory_limit = undefined,
            .cpu_limit = undefined,
            .persist = undefined
        };

        const stats_file = try self.get_file("stats");
        defer stats_file.close();
        stats_file.seekTo(0)
            catch |err| return e.verbose_error(err, error.FailedToGetTaskStats);
        const file_stat = stats_file.stat()
            catch |err| return e.verbose_error(err, error.FailedToGetTaskStats);
        if (file_stat.size > Lengths.HUGE) {
            try log.printdebug("File is too large for buffer", .{});
            return error.FailedToGetTaskStats;
        }
        

        const buf = stats_file.readToEndAlloc(util.gpa, file_stat.size)
            catch |err| return e.verbose_error(err, error.FailedToGetTaskStats);
        defer util.gpa.free(buf);
        var stats_itr = std.mem.splitScalar(u8, buf, '\n');
        var stats_idx: usize = 0;
        while (stats_itr.next()) |val| {
            switch (stats_idx) {
                0 => {
                    stats.cwd = try util.strdup(val, error.FailedToGetTaskStats);
                },
                1 => {
                    stats.command = try util.strdup(val, error.FailedToGetTaskStats);
                },
                2 => {
                    stats.memory_limit = std.fmt.parseInt(util.MemLimit, val, 10)
                        catch |err| return e.verbose_error(err, error.FailedToGetTaskStats);
                },
                3 => {
                    stats.cpu_limit = std.fmt.parseInt(util.CpuLimit, val, 10)
                        catch |err| return e.verbose_error(err, error.FailedToGetTaskStats);
                },
                4 => {
                    stats.persist = std.mem.eql(u8, val, "1");
                },
                else => {
                    return error.FailedToGetTaskStats;
                }
            }
            stats_idx += 1;
        }

        return stats;
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
        var task_dir = try self.get_task_dir();
        defer task_dir.close();
        const file = task_dir.openFile(name, .{.mode = .read_write})
            catch |err| return e.verbose_error(err, error.FailedToGetProcess);
        return file;
    }

    pub fn clear_file(self: *Self, comptime name: []const u8) Errors!void {
        // This is a runtime check which is bad, make this an enum or something
        if (!filename_valid(name)) return error.InvalidFile;
        const file = try self.get_file(name);
        defer file.close();
        file.setEndPos(0)
            catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
        file.seekTo(0)
            catch |err| return e.verbose_error(err, error.TaskFileFailedWrite);
    }

    pub fn write_stats_file(
        self: *Self,
        stats: Stats
    ) Errors!void {
        try self.clear_file("stats");
        const file = try self.get_file("stats");
        defer file.close();
        const stats_str = std.fmt.allocPrintZ(util.gpa, "{s}\n{s}\n{d}\n{d}\n{s}", .{
            stats.cwd, stats.command, stats.memory_limit, stats.cpu_limit, if (stats.persist) "1" else "0"
        }) catch |err| return e.verbose_error(err, error.FailedToSaveStats);
        defer util.gpa.free(stats_str);
        file.writeAll(std.mem.trimRight(u8, stats_str, &[1]u8{0}))
            catch |err| return e.verbose_error(err, error.FailedToSaveStats);
        file.seekTo(0)
            catch |err| return e.verbose_error(err, error.FailedToSaveStats);
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
                err_line = null;
                continue;
            }
            if (err_line == null) {
                log_order.append(.StdOut)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                out_line = null;
                continue;
            }
            const out_data = try get_data_from_line(out_line.?);
            const err_data = try get_data_from_line(err_line.?);
            if (out_data.time < err_data.time) {
                log_order.append(.StdOut)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
                out_line = null;
            } else {
                log_order.append(.StdErr)
                    catch |err| return e.verbose_error(err, error.TaskLogsFailedToRead);
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
            const data = try get_data_from_line(line.?);
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

    pub fn set_task_pid(self: *Self) Errors!void {
        try self.clear_file("task_pid");
        const pid_str = std.fmt.allocPrintZ(util.gpa, "{d}", .{util.get_pid()})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer util.gpa.free(pid_str);
        const task_pid = try self.get_file("task_pid");
        defer task_pid.close();
        _ = task_pid.writeAll(pid_str)
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
    }
};
