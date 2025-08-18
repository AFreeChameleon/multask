const std = @import("std");
const expect = std.testing.expect;
const builtin = @import("builtin");
const log = @import("../log.zig");

const util = @import("../util.zig");
const Lengths = util.Lengths;

const taskproc = @import("./process.zig");
const Process = taskproc.Process;
const Monitoring = taskproc.Monitoring;

const Stats = @import("./stats.zig").Stats;
const Resources = @import("./resources.zig").Resources;

const f = @import("./file.zig");
const Files = f.Files;
const ReadProcess = f.ReadProcess;
const TaskReadProcess = f.TaskReadProcess;

const MainFiles  = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

const t = @import("./index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const JSON_TNamespaces = struct {
    name: []const u8,
    children: []TaskId,

    pub fn deinit(self: *JSON_TNamespaces) void {
        util.gpa.free(self.name);
        util.gpa.free(self.children);
    }
};
const JSON_Tasks = struct {
    task_ids: []TaskId,
    namespaces: []JSON_TNamespaces,

    pub fn deinit(self: *JSON_Tasks) void {
        util.gpa.free(self.task_ids);
        for (self.namespaces) |*ns| {
            ns.deinit();
        }
        util.gpa.free(self.namespaces);
    }
};

pub const TNamespaces = std.StringHashMap([]TaskId);
pub const Tasks = struct {
    task_ids: []TaskId,
    namespaces: TNamespaces,

    pub fn deinit(self: *Tasks) void {
        util.gpa.free(self.task_ids);

        var key_itr = self.namespaces.keyIterator();
        while (key_itr.next()) |key| {
            const val = self.namespaces.get(key.*);
            if (val != null) {
                util.gpa.free(val.?);
            }
            util.gpa.free(key.*);
        }
        self.namespaces.deinit();
    }

    pub fn empty() Tasks {
        return Tasks {
            .task_ids = &std.mem.zeroes([0]TaskId),
            .namespaces = std.StringHashMap([]TaskId).init(util.gpa)
        };
    }

    pub fn json_empty() Errors!JSON_Tasks {
        var placeholder = Tasks.empty();
        defer placeholder.deinit();
        const json_placeholder = JSON_Tasks {
            .namespaces = try TaskManager.ns_to_json(placeholder.namespaces),
            .task_ids = util.gpa.dupe(TaskId, placeholder.task_ids)
                catch |err| return e.verbose_error(err, error.MainFileFailedRead)
        };
        return json_placeholder;
    }
};

pub const TaskManager = struct {
    const Self = @This();

    pub fn save_tasks(tasks: Tasks) Errors!void {
        const file = try MainFiles.get_or_create_tasks_file();
        defer file.close();
        // Clearing before writing
        file.setEndPos(0)
            catch |err| return e.verbose_error(err, error.MainFileFailedWrite);
        file.seekTo(0)
            catch |err| return e.verbose_error(err, error.MainFileFailedWrite);
        const json_ns = try ns_to_json(tasks.namespaces);
        const json_tids = util.gpa.dupe(TaskId, tasks.task_ids)
            catch |err| return e.verbose_error(err, error.MainFileFailedWrite);
        var json_tasks = JSON_Tasks {
            .task_ids = json_tids,
            .namespaces = json_ns
        };
        defer json_tasks.deinit();

        std.json.stringify(json_tasks, .{}, file.writer())
            catch |err| return e.verbose_error(err, error.MainFileFailedWrite);
    }

    /// DEINIT THIS
    pub fn get_tasks() Errors!Tasks {
        const main_file = try MainFiles.get_or_create_tasks_file();
        defer main_file.close();

        const file_content = main_file.readToEndAlloc(util.gpa, 10240)
            catch |err| return e.verbose_error(err, error.MainFileFailedRead);
        defer util.gpa.free(file_content);

        if (file_content.len == 0) {
            return Tasks.empty();
        }
        var json_tasks = std.json.parseFromSlice(
            JSON_Tasks,
            util.gpa,
            file_content,
            .{}
        ) catch |err| return e.verbose_error(err, error.MainFileFailedRead);
        defer json_tasks.deinit();

        const tids_clone = util.gpa.dupe(TaskId, json_tasks.value.task_ids)
            catch |err| return e.verbose_error(err, error.MainFileFailedRead);
        const ns = try json_to_ns(json_tasks.value.namespaces);
        const tasks = Tasks {
            .task_ids = tids_clone,
            .namespaces = ns
        };

        return tasks;
    }

    /// DEINIT
    pub fn json_to_ns(json_ns: []JSON_TNamespaces) Errors!TNamespaces {
        var namespaces: TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
        for (json_ns) |ns| {
            const name_clone = try util.strdup(ns.name, error.MainFileFailedRead);
            const children_clone = util.gpa.dupe(TaskId, ns.children)
                catch |err| return e.verbose_error(err, error.MainFileFailedRead);
            namespaces.put(name_clone, children_clone)
                catch |err| return e.verbose_error(err, error.MainFileFailedRead);
        }
        return namespaces;
    }

    /// DEINIT
    pub fn ns_to_json(ns: TNamespaces) Errors![]JSON_TNamespaces {
        var json_ns = std.ArrayList(JSON_TNamespaces).init(util.gpa);
        defer json_ns.deinit();
        var key_itr = ns.keyIterator();
        while (key_itr.next()) |key| {
            const children = ns.get(key.*);
            if (children != null and children.?.len > 0) {
                json_ns.append(JSON_TNamespaces {
                    .name = try util.strdup(key.*, error.MainFileFailedRead),
                    .children = util.gpa.dupe(TaskId, children.?)
                        catch |err| return e.verbose_error(err, error.MainFileFailedRead),
                }) catch |err| return e.verbose_error(err, error.MainFileFailedRead);
            }
        }
        return json_ns.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.MainFileFailedRead);
    }

    pub fn get_ids_from_namespaces(curr_ns: TNamespaces, namespaces: [][]u8) Errors![]TaskId {
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

    fn find_new_task_id(task_ids: []TaskId) TaskId {
        if (task_ids.len == 0) {
            return 1;
        }
        for (task_ids, 1..) |tid, i| {
            if (tid != i and i < std.math.maxInt(TaskId)) {
                return @intCast(i);
            }
        }
        return task_ids[task_ids.len - 1] + 1;
    }

    pub fn add_task(
        command: []const u8,
        cpu_limit: util.CpuLimit,
        memory_limit: util.MemLimit,
        namespace: ?[]const u8,
        persist: bool,
        monitoring: Monitoring
    ) Errors!Task {
        var tasks = try get_tasks();
        defer tasks.deinit();
        var path_exists = true;
        var new_id = find_new_task_id(tasks.task_ids);
        // Gets task with incrementing id until 1 is free
        while (path_exists) {
            if (!try Files.task_dir_exists(new_id)) {
                path_exists = false;
            } else {
                new_id += 1;
            }
        }

        var tasks_list = util.gpa.alloc(TaskId, tasks.task_ids.len + 1)
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        for (tasks.task_ids, 0..) |tid, i| {
            tasks_list[i] = tid;
        }
        tasks_list[tasks_list.len - 1] = new_id;
        util.gpa.free(tasks.task_ids);
        tasks.task_ids = tasks_list;

        try MainFiles.create_task_files(new_id);

        const cwd = std.fs.cwd().realpathAlloc(util.gpa, ".")
            catch return error.MissingCwd;
        var task = Task {
            .id = new_id,
            .namespace = namespace,
            .stats = Stats {
                .cwd = cwd,
                .command = command,
                .memory_limit = memory_limit,
                .cpu_limit = cpu_limit,
                .persist = persist,
                .monitoring = monitoring
            },
            .files = try Files.init(new_id),
            .resources = Resources.init(),
            .process = null
        };
        try task.files.?.write_file(Stats, task.stats.?);
        
        if (namespace != null) {
            try add_task_to_namespace(&tasks.namespaces, task.id, namespace.?);
        }

        try save_tasks(tasks);

        return task;
    }

    fn add_task_to_namespace(
        curr_ns: *TNamespaces, task_id: TaskId, namespace: []const u8
    ) Errors!void {
        const task_ids = curr_ns.get(namespace);
        if (task_ids == null) {
            var new_ids = util.gpa.alloc(TaskId, 1)
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
            new_ids[0] = task_id;
            const ns_clone = try util.strdup(
                namespace, error.TasksNamespacesFileFailedCreate
            );
            curr_ns.put(ns_clone, new_ids)
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
            return;
        }
        defer util.gpa.free(task_ids.?);

        var ns_plus_one = util.gpa.alloc(TaskId, task_ids.?.len + 1)
            catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);

        for (0..task_ids.?.len) |i| {
            ns_plus_one[i] = task_ids.?[i];
        }

        ns_plus_one[ns_plus_one.len - 1] = task_id;
        curr_ns.put(namespace, ns_plus_one)
            catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedCreate);
    }

    pub fn get_task_from_id(
        task: *Task
    ) Errors!void {
        var tasks = try get_tasks();
        defer tasks.deinit();

        const id_idx = std.mem.indexOfScalar(TaskId, tasks.task_ids, task.id);
        if (id_idx == null) return error.TaskNotExists;
        try log.printdebug("Getting task from id {d}", .{task.id});
        task.namespace = try get_namespace(task.id);
        task.files = try Files.init(task.id);

        const stats = try task.files.?.read_file(Stats);
        if (stats == null) {
            return error.FailedToGetTaskStats;
        }
        task.stats = stats.?;

        var procs = try task.files.?.read_file(ReadProcess);
        if (procs != null) {
            defer procs.?.deinit();
            try log.printdebug("Initialising main process from id", .{});
            const task_args = Process.get_init_args_from_readproc(TaskReadProcess, procs.?.task);
            task.process = try taskproc.parse_readprocess(task, &procs.?);
            task.daemon = try Process.init(task, procs.?.task.pid, task_args);
        }
        task.resources = Resources.init();
    }

    pub fn get_namespace(
        task_id: TaskId
    ) Errors!?[]const u8 {
        var tasks = try get_tasks();
        defer tasks.deinit();

        var key_itr = tasks.namespaces.keyIterator();
        while (key_itr.next()) |key| {
            const task_ids = tasks.namespaces.get(key.*);
            if (task_ids == null or task_ids.?.len == 0)
                continue;

            if (std.mem.indexOfScalar(TaskId, task_ids.?, task_id) != null) {
                return try util.strdup(key.*, error.NamespaceNotExists);
            }
        }
        return null;
    }
};

test "lib/task/manager.zig" {
    std.debug.print("\n--- lib/task/manager.zig ---\n", .{});
}

test "Creating task with namespace" {
    std.debug.print("Creating task with namespace\n", .{});

    const command = try std.fmt.allocPrint(util.gpa, "echo hi", .{});
    const ns = try std.fmt.allocPrint(util.gpa, "ns", .{});
    var new_task = try TaskManager.add_task(
        command,
        20,
        20_000,
        ns,
        false,
        .Shallow
    );
    try expect(new_task.id == 1);
    try expect(std.mem.eql(u8, new_task.namespace.?, "ns"));
    try expect(std.mem.eql(u8, new_task.stats.?.command, "echo hi"));
    try expect(new_task.stats.?.memory_limit == 20_000);
    try expect(new_task.stats.?.cpu_limit == 20);

    try new_task.delete();
    new_task.deinit();
}

test "Reading saved task with namespace" {
    std.debug.print("Reading saved task with namespace\n", .{});

    const command = try std.fmt.allocPrint(util.gpa, "echo hi", .{});
    const ns = try std.fmt.allocPrint(util.gpa, "ns", .{});
    var new_task = try TaskManager.add_task(
        command,
        20,
        20_000,
        ns,
        false,
        .Shallow
    );
    new_task.deinit();
    var task = Task.init(1);
    try TaskManager.get_task_from_id(&task);

    try expect(task.id == 1);
    try expect(std.mem.eql(u8, task.namespace.?, "ns"));
    try expect(std.mem.eql(u8, task.stats.?.command, "echo hi"));
    try expect(task.stats.?.memory_limit == 20_000);
    try expect(task.stats.?.cpu_limit == 20);

    try task.delete();
    task.deinit();
}

test "Creating task with no namespace" {
    std.debug.print("Creating task with namespace\n", .{});

    const command = try std.fmt.allocPrint(util.gpa, "echo hi", .{});
    var new_task = try TaskManager.add_task(
        command,
        20,
        20_000,
        null,
        false,
        .Shallow
    );
    defer new_task.deinit();

    try new_task.delete();
}

test "Reading saved task with no namespace" {
    std.debug.print("Reading saved task with no namespace\n", .{});

    const command = try std.fmt.allocPrint(util.gpa, "echo hi", .{});
    var new_task = try TaskManager.add_task(
        command,
        20,
        20_000,
        null,
        false,
        .Shallow
    );
    new_task.deinit();
    var task = Task.init(1);
    try TaskManager.get_task_from_id(&task);

    try expect(task.id == 1);
    try expect(task.namespace == null);
    try expect(std.mem.eql(u8, task.stats.?.command, "echo hi"));
    try expect(task.stats.?.memory_limit == 20_000);
    try expect(task.stats.?.cpu_limit == 20);

    try task.delete();
    task.deinit();
}
