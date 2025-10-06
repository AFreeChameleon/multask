const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const TaskManager = @import("../task/manager.zig").TaskManager;

const taskproc = @import("../task/process.zig");
const Process = taskproc.Process;

const t = @import("../task/index.zig");
const Task = t.Task;
const TaskId = t.TaskId;

const e = @import("../error.zig");
const Errors = e.Errors;

const util = @import("../util.zig");
const Lengths = util.Lengths;

const log = @import("../log.zig");
const Pid = util.Pid;

const window = @import("../window.zig");
const root = @import("./index.zig");
const GenerateTableType = root.GenerateTableType;

const Row = struct {
    id: []const u8,
    memory_limit: []const u8,
    cpu_limit: []const u8,
    persist: []const u8,
    interactive: []const u8,
    boot: []const u8,
    monitoring: []const u8,
    header: bool,
    table: *Table,

    pub fn init(table: *Table) Row {
        return Row {
            .id = "",
            .memory_limit = "",
            .cpu_limit = "",
            .persist = "",
            .interactive = "",
            .boot = "",
            .monitoring = "",
            .header = false,
            .table = table,
        };
    }

    pub fn deinit(self: *Row) void {
        if (self.header) {
            return;
        }
        util.gpa.free(self.id);
        util.gpa.free(self.memory_limit);
        util.gpa.free(self.cpu_limit);
        util.gpa.free(self.persist);
        util.gpa.free(self.interactive);
        util.gpa.free(self.boot);
        util.gpa.free(self.monitoring);
    }
};

pub const RowWidths = struct {
    id: usize = 0,
    memory_limit: usize = 0,
    cpu_limit: usize = 0,
    persist: usize = 0,
    interactive: usize = 0,
    boot: usize = 0,
    monitoring: usize = 0,
};

pub const Table = GenerateTableType(Row, RowWidths);

pub const TableMethods = struct {
    /// Appending task row to the table
    /// if the child flag is true, it instead adds a child process under the task
    pub fn append_main_row(self: *Table, task: *Task) Errors!void {
        var row = Row.init(self);

        row.id = std.fmt.allocPrint(util.gpa, "{d}", .{task.id})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

        if (task.stats != null) {
            if (task.stats.?.memory_limit > 0) {
                const memory_str = try util.get_readable_memory(task.stats.?.memory_limit);
                row.memory_limit = memory_str;
            } else {
                row.memory_limit = std.fmt.allocPrint(util.gpa, "None", .{})
                    catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            }

            if (task.stats.?.cpu_limit > 0) {
                row.cpu_limit = std.fmt.allocPrint(util.gpa, "{d}%", .{task.stats.?.cpu_limit})
                    catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            } else {
                row.cpu_limit = std.fmt.allocPrint(util.gpa, "None", .{})
                    catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            }

            row.interactive = std.fmt.allocPrint(util.gpa, "{s}", .{
                if (task.stats.?.interactive) "Yes" else "No"
            }) catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

            row.persist = std.fmt.allocPrint(util.gpa, "{s}", .{
                if (task.stats.?.persist) "Yes" else "No"
            }) catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

            row.boot = std.fmt.allocPrint(util.gpa, "{s}", .{
                if (task.stats.?.boot) "Yes" else "No"
            }) catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

            row.monitoring = std.fmt.allocPrint(util.gpa, "{s}", .{
                if (task.stats.?.monitoring == .Deep) "deep" else "shallow"
            }) catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }

        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
    }

    /// Taking a task and converting it into adding table rows
    /// main row with the task, and secondary rows with each process
    pub fn add_task(self: *Table, task: *Task) Errors!void {
        try append_main_row(self, task);
    }

    /// Appending the top headers
    pub fn append_header(self: *Table) Errors!void {
        var row = Row.init(self);
        row.header = true;
        row.id = "id";
        row.memory_limit = "memory limit";
        row.cpu_limit = "cpu limit";
        row.boot = "run on boot";
        row.interactive = "interactive";
        row.persist = "autorestart";
        row.monitoring = "monitoring";
        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
    }

    /// Inserting an erroneous row for when a task is missing some things
    /// likely due to corruption
    pub fn add_corrupted_task(self: *Table, task_id: TaskId) Errors!void {
        var row = Row.init(self);
        row.id = std.fmt.allocPrint(util.gpa, "{d}", .{task_id})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.memory_limit = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.cpu_limit = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.boot = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.interactive = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.persist = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.monitoring = try util.colour_string("Corrupted", 148, 0, 211);
        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
        self.corrupted_rows = true;
    }
};

test "lib/table/stats.zig" {
    std.debug.print("\n--- lib/table/stats.zig ---\n", .{});
}

test "Creating task and putting it in table" {
    std.debug.print("Creating task and putting it in table\n", .{});

    const command = try std.fmt.allocPrint(util.gpa, "echo hi", .{});
    var new_task = try TaskManager.add_task(
        command,
        0,
        0,
        null,
        false,
        .Shallow,
        false,
        false,
    );
    defer {
        new_task.delete() catch @panic("Failed to delete task.");
        new_task.deinit();
    }

    var table = try Table.init(false);
    defer table.deinit();
    try TableMethods.add_task(&table, &new_task);
    try expect(table.rows.items.len == 1);
    try expect(table.corrupted_rows == false);

    const width: usize = 44;
    try expect(table.get_total_row_width() == width);

    table.reset();

    try expect(table.rows.items.len == 0);
}

test "Validating row count for clearing" {
    std.debug.print("Validating row count for clearing\n", .{});

    var table = try Table.init(false);
    defer table.deinit();
    try TableMethods.append_header(&table);
    var row = Row.init(&table);
    row.id = try std.fmt.allocPrint(util.gpa, "1", .{});
    row.memory_limit = try std.fmt.allocPrint(util.gpa, "2G", .{});
    row.cpu_limit = try std.fmt.allocPrint(util.gpa, "20%", .{});
    row.boot = try std.fmt.allocPrint(util.gpa, "Yes", .{});
    row.persist = try std.fmt.allocPrint(util.gpa, "Yes", .{});
    row.interactive = try std.fmt.allocPrint(util.gpa, "No", .{});
    row.monitoring = try std.fmt.allocPrint(util.gpa, "shallow", .{});
    try table.rows.append(row);
    try table.update_row_widths(&row);

    try expect(table.row_widths.id == "id".len + 2);
    try expect(table.row_widths.memory_limit == "memory limit".len + 2);
    try expect(table.row_widths.cpu_limit == "cpu limit".len + 2);
    try expect(table.row_widths.boot == "run on boot".len + 2);
    try expect(table.row_widths.persist == "autorestart".len + 2);
    try expect(table.row_widths.interactive == "interactive".len + 2);
    try expect(table.row_widths.monitoring == "monitoring".len + 2);

    const total_width = table.get_total_row_width();
    const expected_total_width = "| id | memory limit | cpu limit | autorestart | interactive | run on boot | monitoring |".len;
    // std.debug.print("ROW: {s}\n", .{table.rows.items[1]});
    try expect(total_width == expected_total_width);
    const fl_row_width: f32 = @floatFromInt(total_width);

    const row_count = table.rows.items.len + 3;
    const window_cols = 100;
    const total_rows = Table.calculate_total_rows(fl_row_width, window_cols, row_count);
    const table_string = 
        \\+--------------------------------------------------------------------------------------+
        \\| id | memory limit | cpu_limit | autorestart | interactive | run on boot | monitoring |
        \\+--------------------------------------------------------------------------------------+
        \\| 1  | 2G           | 20%       | Yes         | Yes         | No          | shallow    |
        \\+--------------------------------------------------------------------------------------+
        \\
    ;
    const new_lines = std.mem.count(u8, table_string, "\n");

    try expect(new_lines == total_rows);
}

