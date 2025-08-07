const std = @import("std");
const expect = std.testing.expect;
const libc = @import("../c.zig").libc;

const LinuxProcess = @import("./process.zig").LinuxProcess;
const util = @import("../util.zig");
const TaskId = @import("../task/index.zig").TaskId;
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const Lengths = util.Lengths;
const e = @import("../error.zig");
const Errors = e.Errors;
const log = @import("../log.zig");
const MULTASK_TASK_ID = [_]u8 {
    0, 'M', 'U', 'L', 'T', 'A', 'S', 'K', '_', 'T', 'A', 'S', 'K', '_', 'I', 'D', '='
};

pub const TaskReadProcess = struct {
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
        
    pub fn init(proc: *const LinuxProcess) TaskReadProcess {
        return TaskReadProcess {
            .pid = proc.pid,
            .sid = proc.sid,
            .pgrp = proc.pgrp,
            .starttime = proc.starttime,
        };
    }
};
pub const ReadProcess = struct {
    task: TaskReadProcess,
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
    children: ?[]ReadProcess,

    pub fn init(proc: *const LinuxProcess, task_proc: TaskReadProcess, children: ?[]ReadProcess) ReadProcess {
        return ReadProcess {
            .pid = proc.pid,
            .sid = proc.sid,
            .pgrp = proc.pgrp,
            .starttime = proc.starttime,
            .task = task_proc,
            .children = children
        };
    }

    pub fn deinit(self: *ReadProcess) void {
        if (self.children != null) {
            util.gpa.free(self.children.?);
        }
    }

    pub fn clone(self: *const ReadProcess) Errors!ReadProcess {
        const task_proc = TaskReadProcess {
            .pid = self.task.pid,
            .sid = self.task.sid,
            .pgrp = self.task.pgrp,
            .starttime = self.task.starttime,
        };
        const proc = ReadProcess {
            .task = task_proc,
            .pid = self.pid,
            .sid = self.sid,
            .pgrp = self.pgrp,
            .starttime = self.starttime,
            .children = util.gpa.dupe(ReadProcess, self.children.?)
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses)
        };
        return proc;
    }
};

pub const ProcFs = struct {
    /// Gets all stats from the /proc/pid/stat file.
    /// More info, use `man proc` and go to /proc/pid/stat
    pub const Stats = struct {
        val: [][]u8,

        pub fn deinit(self: *const Stats) void {
            defer {
                for (self.val) |stat| {
                    util.gpa.free(stat);
                }
                util.gpa.free(self.val);
            }
        }
    };

    var ARG_MAX: i64 = -1;

    pub const FileType = enum {
        Children,
        Stat,
        Comm,
        Status,
        Statm,
        Environ,

        RootStat,
        RootUptime,
        RootLoadavg
    };

    /// FREE THIS
    pub fn read_file(pid: ?Pid, comptime file_type: FileType) Errors![]u8 {
        if (pid == null) {
            return switch (file_type) {
                FileType.RootStat => try read_root_stat(),
                FileType.RootUptime => try read_root_uptime(),
                FileType.RootLoadavg => try read_root_loadavg(),
                else => return error.InvalidFileType
            };
        } else {
            return switch (file_type) {
                FileType.Children => try read_pid_children(pid.?),
                FileType.Stat => try read_pid_stat(pid.?),
                FileType.Comm => try read_pid_comm(pid.?),
                FileType.Statm => try read_pid_statm(pid.?),
                FileType.Environ => try read_pid_environ(pid.?),
                else => return error.InvalidFileType
            };
        }
    }

    fn read_pid_statm(pid: Pid) Errors![]u8 {
        try log.printdebug("Reading /proc/{d}/statm", .{pid});
        const pid_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/statm", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessMemory);
        defer util.gpa.free(pid_path);
        const statm_file = std.fs.openFileAbsolute(pid_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer statm_file.close();

        const content = statm_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetRootStats);
        return content;
    }

    fn read_root_stat() Errors![]u8 {
        try log.printdebug("Reading /proc/stat", .{});
        const stat_file = std.fs.openFileAbsolute("/proc/stat", .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetRootStats
            });
        defer stat_file.close();
        const content = stat_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetRootStats);
        return content;
    }

    fn read_pid_environ(pid: Pid) Errors![]u8 {
        try log.printdebug("Reading /proc/{d}/environ", .{pid});
        const env_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/environ", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        defer util.gpa.free(env_path);
        const env_file = std.fs.openFileAbsolute(env_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetEnvs
            });
        defer env_file.close();
        if (ARG_MAX == -1) {
            ARG_MAX = libc.sysconf(libc._SC_ARG_MAX);
            if (ARG_MAX == -1) {
                ARG_MAX = Lengths.HUGER;
            }
        }
        const content = env_file.readToEndAlloc(util.gpa, @intCast(ARG_MAX))
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        return content;
    }

    fn read_root_uptime() Errors![]u8 {
        try log.printdebug("Reading /proc/uptime", .{});
        const uptime_file = std.fs.openFileAbsolute("/proc/uptime", .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetSystemUptime
            });
        defer uptime_file.close();
        const content = uptime_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetSystemUptime);
        return content;
    }

    fn read_pid_comm(pid: Pid) Errors![]u8 {
        try log.printdebug("Reading /proc/{d}/comm", .{pid});
        const comm_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/comm", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        defer util.gpa.free(comm_path);
        const comm_file = std.fs.openFileAbsolute(comm_path , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessComm
            });
        defer comm_file.close();
        const content = comm_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return content;
    }

    fn read_root_loadavg() Errors![]u8 {
        try log.printdebug("Reading /proc/loadavg", .{});
        const loadavg_file = std.fs.openFileAbsolute("/proc/loadavg" , .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessComm
            });
        defer loadavg_file.close();
        const content = loadavg_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessComm);
        return content;
    }

    fn read_pid_stat(pid: Pid) Errors![]u8 {
        try log.printdebug("Reading /proc/{d}/stat", .{pid});
        const stat_path = std.fmt.allocPrint(util.gpa, "/proc/{d}/stat", .{pid})
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
        defer util.gpa.free(stat_path);
        const stat_file = std.fs.openFileAbsolute(stat_path, .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessStats
            });
        defer stat_file.close();
        const content = stat_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
        return content;
    }

    fn read_pid_children(pid: Pid) Errors![]u8 {
        try log.printdebug("Reading /proc/{d}/children", .{pid});
        const children_path = std.fmt.allocPrint(
            util.gpa, "/proc/{d}/task/{d}/children", .{ pid, pid }
        ) catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        defer util.gpa.free(children_path);
        const children_file = std.fs.openFileAbsolute(children_path, .{ .mode = .read_only })
            catch |err| return e.verbose_error(err, switch (err) {
                error.FileNotFound => return error.ProcessFileNotFound,
                else => error.FailedToGetProcessChildren
            });
        defer children_file.close();

        const content = children_file.readToEndAlloc(util.gpa, Lengths.HUGE)
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        return content;
    }

    /// Get all entries in /proc
    pub fn get_procs() Errors![]Pid {
        var dir = std.fs.openDirAbsolute("/proc", .{.iterate = true})
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
        if (dir == null) {
            return error.FailedToGetAllProcesses;
        }
        defer dir.?.close();

        var pids = std.ArrayList(Pid).init(util.gpa);
        defer pids.deinit();

        var dir_itr = dir.iterate();
        while (
            dir_itr.next()
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses)
        ) |entry| {
            if (entry.kid != .directory) {
                continue;
            }

            const pid = std.fmt.parseInt(util.Pid, entry.name, 10)
                catch continue;

            pids.append(pid)
                catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
        }

        return pids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
    }

    /// Get all children in /proc/{pid}/task/{pid}/children
    pub fn get_proc_children(pid: Pid) Errors![]Pid {
        var child_pids = std.ArrayList(Pid).init(util.gpa);
        defer child_pids.deinit();

        const content = read_file(pid, FileType.Children)
            catch |err| switch (err) {
                error.ProcessFileNotFound => return &[0]i32{},
                else => return err
        };
        defer util.gpa.free(content);
        var str_child_pids = std.mem.splitScalar(u8, content, ' ');

        while (str_child_pids.next()) |str| {
            if (str.len == 0)
                continue;
            const child_pid = std.fmt.parseInt(Pid, str, 10)
                catch return error.FailedToGetProcessChildren;
            child_pids.append(child_pid)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        }

        return child_pids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
    }

    pub fn get_process_stats(
        pid: Pid
    ) Errors!Stats {
        const content = try read_file(pid, FileType.Stat);
        defer util.gpa.free(content);

        return try parse_linux_file(content, null);
    }

    pub fn get_loadavg() Errors!Stats {
        const content = try read_file(null, FileType.RootLoadavg);
        defer util.gpa.free(content);

        return try parse_linux_file(content, null);
    }

    /// Parses /proc/pid/stat and /proc/loadavg file or just any string separated file.
    fn parse_linux_file(content: []u8, limit: ?u8) Errors!Stats {
        var stats = std.ArrayList([]u8).init(util.gpa);
        defer stats.deinit();
        var stat_line = std.ArrayList([]u8).init(util.gpa);
        defer stat_line.deinit();

        var str_stats = std.mem.splitScalar(u8, content, ' ');

        var bracket_count: i32 = 0;
        while (str_stats.next()) |pstat| {
            if (limit != null and stats.items.len == limit.?) {
                break;
            }
            const trimmed_pstat = std.mem.trim(u8, pstat, "\n");
            const stat = try util.strdup(trimmed_pstat, error.FailedToGetProcessStats);
            if (stat[0] == '(') {
                bracket_count += 1;
            }
            if (stat[stat.len - 1] == ')') {
                bracket_count -= 1;
                if (bracket_count == 0) {
                    stat_line.append(stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                }
            }
            if (bracket_count > 0) {
                stat_line.append(stat)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
            }

            if (bracket_count == 0) {
                if (stat_line.capacity == 0) {
                    stats.append(stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                } else {
                    const str_stat = std.mem.join(util.gpa, " ", stat_line.items)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);
                    stats.append(str_stat)
                        catch |err| return e.verbose_error(err, error.FailedToGetProcessStats);

                    for (stat_line.items) |item| {
                        util.gpa.free(item);
                    }
                    stat_line.clearAndFree();
                }
            }
        }

        return Stats {
            .val = stats.toOwnedSlice()
                catch |err| return e.verbose_error(err, error.FailedToGetProcessStats)
        };
    }

    pub fn get_procs_dir() Errors!std.fs.Dir {
        const dir = std.fs.openDirAbsolute("/proc", .{.iterate = true})
            catch |err| return e.verbose_error(err, error.FailedToGetAllProcesses);
        return dir;
    }

    pub fn proc_has_taskid_in_env(pid: Pid, task_id: TaskId) bool {
        const env_block = read_file(pid, FileType.Environ) catch return false;
        defer util.gpa.free(env_block);

        const envtask_id = find_task_id_from_env_block(env_block) catch return false;

        return envtask_id != null and envtask_id.? == task_id;
    }

    pub fn find_task_id_from_env_block(env_block: []u8) Errors!?TaskId {
        const idx = std.mem.indexOf(u8, env_block, &MULTASK_TASK_ID);
        if (idx == null) {
            return null;
        }
        const start_idx = idx.? + MULTASK_TASK_ID.len;
        var end_idx = idx.? + MULTASK_TASK_ID.len;
        while (env_block[end_idx] != 0) {
            if (end_idx > start_idx + 10) {
                return error.CorruptTaskIdEnvVariable;
            }
            end_idx += 1;
        }

        const trimmed_str_task_id = std.mem.trimRight(u8, env_block[start_idx..end_idx], &[1]u8{0});

        const envtask_id = std.fmt.parseInt(TaskId, trimmed_str_task_id, 10)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        return envtask_id;
    }
};

test "lib/linux/process.zig" {
    std.debug.print("\n--- lib/linux/process.zig ---\n", .{});
}

test "Parse linux /proc/{pid}/stat file contents" {
    std.debug.print("Parse linux /proc/pid/stat file contents\n", .{});

    const content = try std.fmt.allocPrint(util.gpa, "1 (test program) S 2 3", .{});
    defer util.gpa.free(content);
    
    var stats = try ProcFs.parse_linux_file(content, 5);
    defer stats.deinit();

    try expect(std.mem.eql(u8, stats.val[0], "1"));
    try expect(std.mem.eql(u8, stats.val[1], "(test program)"));
    try expect(std.mem.eql(u8, stats.val[2], "S"));
    try expect(std.mem.eql(u8, stats.val[3], "2"));
    try expect(std.mem.eql(u8, stats.val[4], "3"));
}

test "Parse linux /proc/loadavg file contents" {
    std.debug.print("Parse linux /proc/loadavg file contents\n", .{});

    const content = try std.fmt.allocPrint(util.gpa, "2.35 2.07 1.60 1/1535 34838\n", .{});
    defer util.gpa.free(content);
    
    var stats = try ProcFs.parse_linux_file(content, 5);
    defer stats.deinit();

    try expect(std.mem.eql(u8, stats.val[0], "2.35"));
    try expect(std.mem.eql(u8, stats.val[1], "2.07"));
    try expect(std.mem.eql(u8, stats.val[2], "1.60"));
    try expect(std.mem.eql(u8, stats.val[3], "1/1535"));
    try expect(std.mem.eql(u8, stats.val[4], "34838"));
}

test "Parse linux /proc/{pid}/environ file contents" {
    std.debug.print("Parse linux /proc/pid/environ file contents\n", .{});
    const content = try std.fmt.allocPrint(util.gpa, "KEY=VAL\x00KEY2=VAL2\x00MULTASK_TASK_ID=15\x00KEY3=VAL3\x00", .{});
    defer util.gpa.free(content);

    const task_id = try ProcFs.find_task_id_from_env_block(content);
    try expect(task_id != null and task_id == 15);
}
