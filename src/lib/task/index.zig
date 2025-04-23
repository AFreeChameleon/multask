const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

const util = @import("../util.zig");
const Lengths = util.Lengths;

const Process = @import("./process.zig").Process;
const Stats = @import("./stats.zig").Stats;
const Resources = @import("./resources.zig").Resources;

const f = @import("./file.zig");
const Files = f.Files;

const MainFiles  = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

pub const TaskId = i32;

pub const Task = struct {
    const Self = @This();

    id: TaskId,
    pid: util.Pid = 0, // We can't set pid now, it has to be after fork happens
    namespace: ?[]const u8,
    files: Files,
    process: Process,
    stats: Stats,
    resources: Resources,

    pub fn deinit(self: *Self) void {
        self.stats.deinit();
        self.resources.deinit();

        if (self.namespace != null)
            util.gpa.free(self.namespace.?);
    }

    pub fn refresh(self: *Self) Errors!void {
        self.pid = try self.files.read_task_pid_file();
        self.stats = try self.files.read_stats_file();
        const procs = try self.files.read_processes_file();
        try log.printdebug("Initialising main process", .{});
        if (procs.pid != self.process.get_pid()) {
            self.process = try Process.init(procs.pid, self);
        }
    }
};

pub const TaskManager = struct {
    /// Reads taskids from the /tasks/ids file
    /// FREE THIS
    pub fn get_taskids() Errors![]TaskId {
        var tasksids_file = try MainFiles.get_or_create_taskids_file();
        defer tasksids_file.close();
        if (
            (tasksids_file.getEndPos()
                catch |err| return e.verbose_error(
                    err, error.TasksFileMissingOrCorrupt
            )) == 0
        ) {
            return &.{};
        }
        var tasks_list = std.ArrayList(TaskId).init(util.gpa);
        defer tasks_list.deinit();

        var buf_reader = std.io.bufferedReader(tasksids_file.reader());
        var reader = buf_reader.reader();

        var buf: [Lengths.MEDIUM]u8 = std.mem.zeroes([Lengths.MEDIUM]u8);
        var buf_fbs = std.io.fixedBufferStream(&buf);
        while (
            true
        ) {
            reader.streamUntilDelimiter(buf_fbs.writer(), ',', buf_fbs.buffer.len)
                catch |err| switch (err) {
                    error.NoSpaceLeft => break,
                    error.EndOfStream => break,
                    else => |inner_err| return e.verbose_error(
                        inner_err, error.TasksFileMissingOrCorrupt
                    )
                };
            const it = buf_fbs.getWritten();
            defer buf_fbs.reset();
            if (it.len == 0) {
                break;
            }
            const task_id = std.fmt.parseInt(TaskId, it, 10)
                catch |err| return e.verbose_error(err, error.TasksFileMissingOrCorrupt);
            tasks_list.append(task_id)
                catch |err| return e.verbose_error(err, error.TasksFileMissingOrCorrupt);
        }
        const duped_tasks = util.gpa.dupe(TaskId, tasks_list.items)
            catch |err| return e.verbose_error(err, error.TasksFileMissingOrCorrupt);
        return duped_tasks;
    }

    pub fn get_ids_from_namespaces(namespaces: [][]u8) Errors![]TaskId {
        const curr_ns = try get_namespaces();
        var task_ids = std.ArrayList(TaskId).init(util.gpa);
        defer task_ids.deinit();

        for (namespaces) |ns| {
            const ns_tids = curr_ns.get(ns);
            if (ns_tids == null) continue;
            task_ids.appendSlice(ns_tids.?)
                catch |err| return e.verbose_error(err, error.NamespaceValueMissing);
        }

        return task_ids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.NamespaceValueMissing);
    }

    /// Returns the namespaces from the .multi-tasker/tasks/namespaces file
    /// as a hashmap of "name": 1,2,3
    /// DEINIT THIS
    pub fn get_namespaces() Errors!std.StringHashMap([]TaskId) {
        var ns = std.StringHashMap([]TaskId).init(util.gpa);
        defer ns.deinit();
        var ns_file = try MainFiles.get_or_create_namespaces_file();
        defer ns_file.close();

        if (
            (ns_file.getEndPos()
                catch |err| return e.verbose_error(
                    err, error.TasksNamespacesFileFailedRead
            )) == 0
        ) {
            return ns;
        }

        var buf_reader = std.io.bufferedReader(ns_file.reader());
        var reader = buf_reader.reader();

        var buf: [Lengths.MEDIUM]u8 = std.mem.zeroes([Lengths.MEDIUM]u8);
        var buf_fbs = std.io.fixedBufferStream(&buf);
        while (
            true
        ) {
            reader.streamUntilDelimiter(buf_fbs.writer(), '\n', buf_fbs.buffer.len)
                catch |err| switch (err) {
                    error.NoSpaceLeft => break,
                    error.EndOfStream => break,
                    else => |inner_err| return e.verbose_error(
                        inner_err, error.TasksNamespacesFileFailedRead
                    )
                };
            const it = buf_fbs.getWritten();
            defer buf_fbs.reset();
            if (it.len == 0) {
                break;
            }
            var line_itr = std.mem.splitAny(u8, it, ":,");
            const ns_name = try util.strdup(
                line_itr.first(), error.TasksNamespacesFileFailedRead
            );
            var ns_ids = std.ArrayList(TaskId).init(util.gpa);
            defer ns_ids.deinit();
            while (line_itr.next()) |str_tid| {
                if (str_tid.len == 0) break;
                const id = std.fmt.parseInt(TaskId, str_tid, 10)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedRead);
                ns_ids.append(id)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedRead);
            }
            const owned_ns_ids = ns_ids.toOwnedSlice()
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedRead);
            ns.put(ns_name, owned_ns_ids)
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedRead);
        }
        return ns.clone()
            catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedRead);
    }

    pub fn save_namespaces(namespaces: *std.StringHashMap([]TaskId)) Errors!void {
        try MainFiles.clear_namespaces_file();
        var file = try MainFiles.get_or_create_namespaces_file();
        defer file.close();

        var writer = std.io.bufferedWriter(file.writer());
        var keys = namespaces.keyIterator();
        while (keys.next()) |key| {
            const val = namespaces.get(key.*);
            if (val == null) continue;

            const name = std.fmt.allocPrint(util.gpa, "{s}:", .{key.*})
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
            defer util.gpa.free(name);

            _ = writer.write(try util.strdup(name, error.TasksNamespacesFileFailedCreate))
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);

            for (val.?) |task_id| {
                const str_tid = std.fmt.allocPrint(util.gpa, "{d},", .{task_id})
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
                defer util.gpa.free(str_tid);

                _ = writer.write(try util.strdup(str_tid, error.TasksNamespacesFileFailedCreate))
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
            }
            _ = writer.write("\n")
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
        }
        writer.flush()
            catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
    }

    pub fn get_task(tasks: []Task, id: TaskId) Task {
        var task = undefined;
        for (tasks) |t| {
            if (t.id == id) {
                task = t;
            }
        }
        return task;
    }

    pub fn save_taskids(new_tasks: []TaskId) Errors!void {
        try MainFiles.clear_taskids_file();
        var tasks_file = try MainFiles.get_or_create_taskids_file();
        defer tasks_file.close();

        var ids_string = std.ArrayList(u8).init(util.gpa);
        defer ids_string.deinit();

        for (new_tasks) |t| {
            var buf: [Lengths.SMALL]u8 = undefined;
            const string_id = std.fmt.bufPrint(&buf, "{d},", .{t})
                catch |err| return e.verbose_error(err, error.TasksFileMissingOrCorrupt);
            ids_string.appendSlice(string_id)
                catch |err| return e.verbose_error(err, error.TasksFileMissingOrCorrupt);
        }
        _ = tasks_file.write(ids_string.items)
            catch |err| return e.verbose_error(err, error.TasksFileMissingOrCorrupt);
    }

    pub fn add_task(
        command: []const u8,
        cpu_limit: util.CpuLimit,
        memory_limit: util.MemLimit,
        namespace: ?[]const u8,
        persist: bool
    ) Errors!Task {
        const task_ids = try get_taskids();
        var path_exists = true;
        var new_id: TaskId = if (task_ids.len > 0)
            task_ids[task_ids.len - 1] + 1 else 1;
        // Gets task with incrementing id until 1 is free
        while (path_exists) {
            if (!try Files.task_dir_exists(new_id)) {
                path_exists = false;
            } else {
                new_id += 1;
            }
        }

        var tasks_list = std.ArrayList(TaskId).init(util.gpa);
        defer tasks_list.deinit();
        tasks_list.insertSlice(0, task_ids)
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        tasks_list.append(new_id)
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);

        try MainFiles.create_task_files(new_id);
        try save_taskids(tasks_list.items);

        const cwd = std.fs.cwd().realpathAlloc(util.gpa, ".")
            catch return error.MissingCwd;
        defer util.gpa.free(cwd);
        var task = Task {
            .id = new_id,
            .namespace = namespace,
            .stats = Stats {
                .cwd = try util.strdup(cwd, error.TaskFileFailedCreate),
                .command = command,
                .memory_limit = memory_limit,
                .cpu_limit = cpu_limit,
                .persist = persist
            },
            .files = undefined,
            .resources = undefined,
            .process = undefined
        };
        task.files = try Files.init(task.id);

        try task.files.write_stats_file(task.stats);
        
        try add_task_to_namespace(task.id, namespace);

        return task;
    }

    fn add_task_to_namespace(task_id: TaskId, namespace: ?[]const u8) Errors!void {
        var namespaces = try get_namespaces();
        defer namespaces.deinit();
        const specified_ns: [2][]const u8 = if (namespace == null)
            [2][]const u8{"all", ""}
        else
            [2][]const u8{"all", namespace.?};
        // Adding to all and particular namespace
        for (specified_ns) |item| {
            if (item.len == 0) continue;
            const ns = namespaces.get(item);
            if (ns == null) {
                var new_ids = util.gpa.alloc(TaskId, 1)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
                defer util.gpa.free(new_ids);
                new_ids[0] = task_id;
                namespaces.put(item, util.gpa.dupe(TaskId, new_ids)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate)
                ) catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
            } else {
                var ns_plus_one = util.gpa.alloc(TaskId, ns.?.len + 1)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
                defer util.gpa.free(ns_plus_one);

                for (0..ns.?.len) |i| {
                    ns_plus_one[i] = ns.?[i];
                }
                ns_plus_one[ns_plus_one.len - 1] = task_id;
                namespaces.put(item, util.gpa.dupe(TaskId, ns_plus_one)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate)
                ) catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
            }
        }

        try save_namespaces(&namespaces);
    }

    pub fn get_task_from_id(
        task_id: TaskId
    ) Errors!Task {
        const task_ids = try get_taskids();
        const id_idx = std.mem.indexOf(TaskId, task_ids, &[1]TaskId{task_id});
        if (id_idx == null) return error.TaskNotExists;
        var task = Task {
            .id = task_id,
            .namespace = undefined,
            .files = undefined,
            .stats = undefined,
            .process = undefined,
            .resources = undefined
        };
        try log.printdebug("Getting task from id {d}", .{task_id});
        task.namespace = try get_namespace(task.id);
        task.files = try Files.init(task.id);
        task.stats = try task.files.read_stats_file();
        const procs = try task.files.read_processes_file();
        try log.printdebug("Initialising main process", .{});
        task.process = try Process.init(procs.pid, &task);
        return task;
    }

    pub fn get_namespace(task_id: TaskId) Errors!?[]const u8 {
        var namespaces = try get_namespaces();
        defer namespaces.deinit();
        var key_itr = namespaces.keyIterator();
        while (key_itr.next()) |key| {
            if (std.mem.eql(u8, key.*, "all"))
                continue;

            const task_ids = namespaces.get(key.*);
            if (task_ids == null or task_ids.?.len == 0)
                continue;

            if (std.mem.indexOfScalar(TaskId, task_ids.?, task_id) != null) {
                return key.*;
            }
        }
        return null;
    }
};
