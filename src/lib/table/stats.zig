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

const MAX_COL_LEN = 32;

const StatsRow = struct {
    id: []u8,
    memory_limit: []u8,
    cpu_limit: []u8,
    persist: []u8,
    interactive: []u8,
    boot: []u8,
    monitoring: []u8,

    pub fn alloc() Errors!StatsRow {
        const val = StatsRow {
            .id = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .memory_limit = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .cpu_limit = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .persist = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .interactive = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .boot = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
            .monitoring = util.gpa.alloc(u8, MAX_COL_LEN)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow),
        };
        @memset(val.id, 0);
        @memset(val.memory_limit, 0);
        @memset(val.cpu_limit, 0);
        @memset(val.persist, 0);
        @memset(val.interactive, 0);
        @memset(val.boot, 0);
        @memset(val.monitoring, 0);
        return val;
    }

    pub fn deinit(row: *const StatsRow) void {
        util.gpa.free(row.id);
        util.gpa.free(row.memory_limit);
        util.gpa.free(row.cpu_limit);
        util.gpa.free(row.persist);
        util.gpa.free(row.interactive);
        util.gpa.free(row.boot);
        util.gpa.free(row.monitoring);
    }
};

const Table = flute.table.GenerateTableType(StatsRow);

pub fn init_table() Errors!Table {
    const table = try Table.init(util.gpa);
    return table;
}

pub fn create_header() Errors!StatsRow {
    var row = try StatsRow.alloc();
    helper.apply_header_val(StatsRow, &row, "id");
    helper.apply_key_val(StatsRow, &row, "memory_limit", "memory limit");
    helper.apply_key_val(StatsRow, &row, "cpu_limit", "cpu limit");
    helper.apply_key_val(StatsRow, &row, "persist", "autorestart");
    helper.apply_header_val(StatsRow, &row, "interactive");
    helper.apply_key_val(StatsRow, &row, "boot", "run on boot");
    helper.apply_header_val(StatsRow, &row, "monitoring");
    return row;
}

/// Inserting an erroneous row for when a task is missing some things
/// likely due to corruption
pub fn create_corrupted_task(task_id: TaskId) Errors!StatsRow {
    var row = try StatsRow.alloc();

    _ = std.fmt.bufPrint(row.id, "{d}", .{task_id})
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    helper.apply_key_val(StatsRow, &row, "memory_limit", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));
    helper.apply_key_val(StatsRow, &row, "cpu_limit", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));
    helper.apply_key_val(StatsRow, &row, "persist", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));
    helper.apply_key_val(StatsRow, &row, "interactive", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));
    helper.apply_key_val(StatsRow, &row, "boot", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));
    helper.apply_key_val(StatsRow, &row, "monitoring", flute.format.string.colorStringComptime(.{148, 0, 211}, "Corrupted"));

    return row;
}

pub fn set_stats_table(table: *Table, task_ids: []TaskId) Errors!bool {
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
        add_task(table, &task) catch |err| {
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

/// Taking a task and converting it into adding table rows
/// main row with the task, and secondary rows with each process
pub fn add_task(table: *Table, task: *Task) Errors!void {
    if (task.stats == null) {
        table.addRow(try create_corrupted_task(task.id))
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
    var row = try StatsRow.alloc();
    _ = std.fmt.bufPrint(row.id, "{d}", .{task.id})
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    if (task.stats.?.memory_limit > 0) {
        var memory_buf: [128]u8 = undefined;
        const memory_str = try util.get_readable_memory(&memory_buf, task.stats.?.memory_limit);
        if (memory_str.len <= MAX_COL_LEN) {
            @memcpy(row.memory_limit[0..memory_str.len], memory_str);
        } else {
            _ = std.fmt.bufPrint(row.memory_limit, "{s}...", .{memory_str[0..MAX_COL_LEN - 3]})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }
    } else {
        @memcpy(row.memory_limit[0..4], "None");
    }

    if (task.stats.?.cpu_limit > 0) {
        _ = std.fmt.bufPrint(row.cpu_limit, "{d}%", .{task.stats.?.cpu_limit})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    } else {
        @memcpy(row.cpu_limit[0..4], "None");
    }

    if (task.stats.?.interactive) {
        @memcpy(row.interactive[0..3], "Yes");
    } else {
        @memcpy(row.interactive[0..2], "No");
    }

    if (task.stats.?.persist) {
        @memcpy(row.persist[0..3], "Yes");
    } else {
        @memcpy(row.persist[0..2], "No");
    }

    if (task.stats.?.boot) {
        @memcpy(row.boot[0..3], "Yes");
    } else {
        @memcpy(row.boot[0..2], "No");
    }

    if (task.stats.?.monitoring == .Deep) {
        @memcpy(row.monitoring[0..4], "deep");
    } else {
        @memcpy(row.monitoring[0..7], "shallow");
    }

    table.addRow(row)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
}

pub fn print_table(table: *Table, writer: anytype) Errors!void {
    try helper.print_table(Table, table, writer);
}

pub fn free_table_rows(table: *Table) void {
    helper.free_table_rows(Table, table);
}

pub fn reset_table(table: *Table) Errors!void {
    try helper.reset_table(Table, table);
}
