const std = @import("std");
const flute = @import("flute");

const e = @import("../error.zig");
const Errors = e.Errors;

const log = @import("../log.zig");

const util = @import("../util.zig");
const Pid = util.Pid;
const TaskArgs = util.TaskArgs;

const t = @import("../task/index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const taskproc = @import("../task/process.zig");
const Process = taskproc.Process;

const TaskManager = @import("../task/manager.zig").TaskManager;

const helper = @import("./helper.zig");

const ProcStatus = enum {
    Headless,
    Running,
    Restarting,
    Detached,
    Stopped
};

const MAX_COL_LEN = 32;

const MainRow = struct {
    id: []u8,
    namespace: []u8,
    command: []u8,
    location: []u8,
    pid: []u8,
    status: []u8,
    memory: []u8,
    cpu: []u8,
    runtime: []u8,

    pub fn alloc() Errors!MainRow {
        const val = MainRow {
            .id = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .namespace = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .command = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .location = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .pid = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .status = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .memory = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .cpu = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .runtime = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
        };
        @memset(val.id, 0);
        @memset(val.namespace, 0);
        @memset(val.command, 0);
        @memset(val.location, 0);
        @memset(val.pid, 0);
        @memset(val.status, 0);
        @memset(val.memory, 0);
        @memset(val.cpu, 0);
        @memset(val.runtime, 0);
        return val;
    }

    pub fn deinit(row: *const MainRow) void {
        util.gpa.free(row.id);
        util.gpa.free(row.namespace);
        util.gpa.free(row.command);
        util.gpa.free(row.location);
        util.gpa.free(row.pid);
        util.gpa.free(row.status);
        util.gpa.free(row.memory);
        util.gpa.free(row.cpu);
        util.gpa.free(row.runtime);
    }
};

const Table = flute.table.GenerateTableType(MainRow);

pub fn init_table() Errors!Table {
    const table = try Table.init(util.gpa);
    return table;
}

pub fn set_main_table(table: *Table, task_ids: []TaskId, show_all: bool) Errors!bool {
    const header = try create_header();
    table.addRow(header)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    var is_corrupted = false;

    for (task_ids) |task_id| {
        var task = Task.init(task_id);
        defer task.deinit();
        TaskManager.get_task_from_id(&task) catch |err| {
            try log.printdebug("{any}", .{err});
            const corrupted = try create_corrupted_task(task_id);
            table.addRow(corrupted)
                catch |inner_err| return e.verbose_error(inner_err, error.FailedAppendTableRow);
            is_corrupted = true;
            continue;
        };
        task.resources.?.set_cpu_usage(&task) catch |err| {
            try log.printdebug("{any}", .{err});
            const corrupted = try create_corrupted_task(task_id);
            table.addRow(corrupted)
                catch |inner_err| return e.verbose_error(inner_err, error.FailedAppendTableRow);
            is_corrupted = true;
            continue;
        };
        add_task(table, &task, show_all) catch |err| {
            try log.printdebug("{any}", .{err});
            const corrupted = try create_corrupted_task(task_id);
            table.addRow(corrupted)
                catch |inner_err| return e.verbose_error(inner_err, error.FailedAppendTableRow);
            is_corrupted = true;
            continue;
        };
    }
    return is_corrupted;
}

pub fn print_table(table: *Table, writer: anytype) Errors!void {
    try helper.print_table(Table, table, writer);
}

pub fn reset_table(table: *Table) Errors!void {
    try helper.reset_table(Table, table);
}

pub fn free_table_rows(table: *Table) void {
    helper.free_table_rows(Table, table);
}

pub fn create_header() Errors!MainRow {
    var row = try MainRow.alloc();
    helper.apply_header_val(MainRow, &row, "id");
    helper.apply_header_val(MainRow, &row, "namespace");
    helper.apply_header_val(MainRow, &row, "command");
    helper.apply_header_val(MainRow, &row, "location");
    helper.apply_header_val(MainRow, &row, "pid");
    helper.apply_header_val(MainRow, &row, "status");
    helper.apply_header_val(MainRow, &row, "memory");
    helper.apply_header_val(MainRow, &row, "cpu");
    helper.apply_header_val(MainRow, &row, "runtime");
    return row;
}

/// Taking a task and converting it into adding table rows
/// main row with the task, and secondary rows with each process
pub fn add_task(table: *Table, task: *Task, show_all: bool) Errors!void {
    const row = try create_main_row(task);
    table.addRow(row)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    if (task.process == null) {
        return;
    }

    if (!task.process.?.proc_exists()) {
        const proc_rows = try create_saved_task_process_rows(task, show_all);
        if (proc_rows != null) {
            table.addRows(proc_rows.?)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }
    } else {
        const proc_rows = try create_task_process_rows(task, show_all);
        defer util.gpa.free(proc_rows);
        table.addRows(proc_rows)
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
}

/// Inserting an erroneous row for when a task is missing some things
/// likely due to corruption
pub fn create_corrupted_task(task_id: TaskId) Errors!MainRow {
    var row = try MainRow.alloc();

    _ = std.fmt.bufPrint(row.id, "{d}", .{task_id})
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    helper.apply_key_val(MainRow, &row, "command", "Error");
    helper.apply_key_val(MainRow, &row, "location", "N/A");
    helper.apply_key_val(MainRow, &row, "pid", "N/A");
    helper.apply_key_val(MainRow, &row, "status", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));
    helper.apply_key_val(MainRow, &row, "memory", "N/A");
    helper.apply_key_val(MainRow, &row, "cpu", "N/A");
    helper.apply_key_val(MainRow, &row, "runtime", "N/A");

    return row;
}

/// Sets the exe column to the process' name
fn set_child_process_columns(row: *MainRow, some_proc: ?*Process) Errors!void {
    var cmd_buf: [33]u8 = undefined;
    const exe = try some_proc.?.get_exe_buf(&cmd_buf);
    if (exe.len > MAX_COL_LEN) {
        _ = std.fmt.bufPrint(row.command, "{s}...", .{exe[0..MAX_COL_LEN - 3]})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    } else {
        _ = std.fmt.bufPrint(row.command, "{s}", .{exe})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
}

/// Sets the id, namespace & command columns
fn set_parent_process_columns(row: *MainRow, task: *Task) Errors!void {
    _ = std.fmt.bufPrint(row.id, "{d}", .{task.id})
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    if (task.namespace == null) {
        @memcpy(row.namespace[0..3], "N/A");
    } else {
        if (task.namespace.?.len > MAX_COL_LEN) {
            _ = std.fmt.bufPrint(row.namespace, "{s}...", .{task.namespace.?[0..MAX_COL_LEN - 3]})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        } else {
            _ = std.fmt.bufPrint(row.namespace, "{s}", .{task.namespace.?})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }
    }

    if (task.stats.?.command.len > MAX_COL_LEN) {
        _ = std.fmt.bufPrint(row.command, "{s}...", .{task.stats.?.command[0..MAX_COL_LEN - 3]})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    } else {
        _ = std.fmt.bufPrint(row.command, "{s}", .{task.stats.?.command})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
}

fn set_killed_process_columns(row: *MainRow) void {
    helper.apply_key_val(MainRow, row, "pid", "N/A");
    helper.apply_key_val(MainRow, row, "status", get_proc_status_string(ProcStatus.Stopped));
    helper.apply_key_val(MainRow, row, "memory", "N/A");
    helper.apply_key_val(MainRow, row, "cpu", "N/A");
    helper.apply_key_val(MainRow, row, "runtime", "N/A");
}

fn set_alive_process_columns(row: *MainRow, task: *Task, some_proc: ?*Process) Errors!void {
    var proc = some_proc.?;
    _ = std.fmt.bufPrint(row.pid, "{d}", .{proc.pid})
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    const status = try get_proc_status(task, proc);
    _ = std.fmt.bufPrint(row.status, "{s}", .{status})
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    var memory_buf: [128]u8 = undefined;
    const memory_str = try util.get_readable_memory(&memory_buf, try proc.get_memory());
    if (memory_str.len > MAX_COL_LEN) {
        _ = std.fmt.bufPrint(row.memory, "{s}...", .{memory_str[0..MAX_COL_LEN - 3]})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    } else {
        _ = std.fmt.bufPrint(row.memory, "{s}", .{memory_str})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }

    const cpu_int = task.resources.?.cpu.get(proc.pid);
    if (cpu_int == null) {
        @memcpy(row.cpu[0..3], "N/A");
    } else {
        var cpu_buf: [128]u8 = undefined;
        const cpu_perc_str = try util.get_readable_cpu_usage(&cpu_buf, cpu_int.?);
        if (cpu_perc_str.len > MAX_COL_LEN) {
            _ = std.fmt.bufPrint(row.cpu, "{s}...", .{cpu_perc_str[0..MAX_COL_LEN - 3]})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        } else {
            _ = std.fmt.bufPrint(row.cpu, "{s}", .{cpu_perc_str})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }
    }

    var runtime_buf: [128]u8 = undefined;
    const runtime_str = try util.get_readable_runtime(&runtime_buf, try proc.get_runtime());
    if (runtime_str.len > MAX_COL_LEN) {
        _ = std.fmt.bufPrint(row.runtime, "{s}...", .{runtime_str[0..MAX_COL_LEN - 3]})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    } else {
        _ = std.fmt.bufPrint(row.runtime, "{s}", .{runtime_str})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
}

fn get_enum_proc_status(task: *Task, some_proc: ?*Process) Errors!ProcStatus {
    if (some_proc != null) {
        var proc = some_proc.?;
        // Does inner process exist
        if (proc.proc_exists()) {
            if (task.daemon == null or !task.daemon.?.proc_exists()) {
                return ProcStatus.Headless;
            }
            return ProcStatus.Running;
        }
        if (task.daemon != null) {
            const daemon_exists = task.daemon.?.proc_exists();
            if (daemon_exists and task.stats.?.persist) {
                // The child command hasn't been run but the parent task proc is waiting
                return ProcStatus.Restarting;
            } else if (daemon_exists) {
                const saved_procs = try taskproc.get_running_saved_procs(proc);
                defer util.gpa.free(saved_procs);
                if (saved_procs.len != 0) {
                    return ProcStatus.Detached;
                }
            }
        }
    }
    return ProcStatus.Stopped;
}

fn get_proc_status_string(status: ProcStatus) []const u8 {
    return switch (status) {
        ProcStatus.Headless => flute.format.string.colorStringComptime([3]u8{204, 0, 0}, "Headless"),
        ProcStatus.Running => flute.format.string.colorStringComptime([3]u8{0, 204, 102}, "Running"),
        ProcStatus.Restarting => flute.format.string.colorStringComptime([3]u8{204, 102, 0}, "Restarting"),
        ProcStatus.Detached => flute.format.string.colorStringComptime([3]u8{204, 102, 0}, "Detached"),
        ProcStatus.Stopped => flute.format.string.colorStringComptime([3]u8{204, 0, 0}, "Stopped"),
    };
}

fn get_proc_status(task: *Task, some_proc: ?*Process) Errors![]const u8 {
    const status = try get_enum_proc_status(task, some_proc);

    return get_proc_status_string(status);
}

/// Setting task row
fn create_main_row(
    task: *Task
) Errors!MainRow {
    var row = try MainRow.alloc();
    const some_proc = if (task.process == null) null else &task.process.?;
    try set_parent_process_columns(&row, task);

    if (task.stats.?.cwd.len > MAX_COL_LEN) {
        const concat_str = task.stats.?.cwd[
            (task.stats.?.cwd.len - (MAX_COL_LEN - 3))..(task.stats.?.cwd.len)
        ];
        @memcpy(row.location[0..concat_str.len], concat_str);
    } else {
        @memcpy(row.location[0..task.stats.?.cwd.len], task.stats.?.cwd);
    }

    if (some_proc == null or !some_proc.?.proc_exists()) {
        set_killed_process_columns(&row);
    } else {
        try set_alive_process_columns(&row, task, some_proc);
    }

    return row;
}

/// Setting process row
fn create_process_row(
    task: *Task, process: *Process
) Errors!MainRow {
    var row = try MainRow.alloc();
    try set_child_process_columns(&row, process);

    if (task.stats.?.cwd.len > MAX_COL_LEN) {
        const concat_str = task.stats.?.cwd[
            (task.stats.?.cwd.len - (MAX_COL_LEN - 3))..(task.stats.?.cwd.len)
        ];
        @memcpy(row.location[0..concat_str.len], concat_str);
    } else {
        @memcpy(row.location[0..task.stats.?.cwd.len], task.stats.?.cwd);
    }

    try set_alive_process_columns(&row, task, process);
    return row;
}

fn create_truncated_processes_row(saved_procs_len: usize) Errors!MainRow {
    const row = try MainRow.alloc();

    _ = std.fmt.bufPrint(
        row.command, " + {d} more process{s}", .{
            saved_procs_len, if (saved_procs_len != 1) "es" else ""
        }) catch |err| return e.verbose_error(
            err, error.FailedAppendTableRow
        );

    return row;
}

fn create_saved_task_process_rows(task: *Task, show_all: bool) Errors!?[]MainRow {
    const saved_procs = try taskproc.get_running_saved_procs(&task.process.?);
    defer util.gpa.free(saved_procs);
    if (saved_procs.len == 0) {
        return null;
    }

    var rows = std.ArrayList(MainRow).init(util.gpa);
    defer rows.deinit();
    if (!show_all) {
        const row = try create_truncated_processes_row(saved_procs.len);
        rows.append(row)
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    } else {
        for (0..saved_procs.len) |i| {
            const row = try create_process_row(task, &saved_procs[i]);
            rows.append(row)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }
    }
    return rows.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
}

fn create_task_process_rows(task: *Task, show_all: bool) Errors![]MainRow {
    var rows = std.ArrayList(MainRow).init(util.gpa);
    defer rows.deinit();

    if (task.process == null or task.process.?.children == null) {
        return rows.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }

    if (!show_all) {
        var proc_len = task.process.?.children.?.len;
        for (task.process.?.children.?) |proc| {
            if (task.daemon != null and proc.pid == task.daemon.?.pid) {
                proc_len -= 1;
            }
        }
        if (proc_len > 0) {
            const row = try create_truncated_processes_row(proc_len);
            rows.append(row)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }
    } else {
        if (task.process.?.children != null) {
            for (0..task.process.?.children.?.len) |i| {
                const row = try create_process_row(task, &task.process.?.children.?[i]);
                rows.append(row)
                    catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            }
        }
    }
    return rows.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
}

// Removes any old tasks
fn check_taskids(targs: TaskArgs) Errors![]TaskId {
    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    if (!targs.parsed) {
        return util.gpa.dupe(TaskId, tasks.task_ids) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    var new_ids = std.ArrayList(TaskId).init(util.gpa);
    defer new_ids.deinit();

    // namespace ids + regular selected ids
    var selected_id_list = std.ArrayList(TaskId).init(util.gpa);
    defer selected_id_list.deinit();
    selected_id_list.appendSlice(targs.ids.?) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    if (targs.namespaces != null) {
        selected_id_list.appendSlice(try TaskManager.get_ids_from_namespaces(tasks.namespaces, targs.namespaces.?)) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
    const selected_ids = try util.unique_array(TaskId, selected_id_list.items);
    defer util.gpa.free(selected_ids);

    for (selected_ids) |tid| {
        if (std.mem.indexOfScalar(TaskId, tasks.task_ids, tid) != null) {
            new_ids.append(tid) catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        }
    }
    const owned_new_ids = new_ids.toOwnedSlice() catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    return owned_new_ids;
}
