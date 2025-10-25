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

const ProcStatus = enum {
    Headless,
    Running,
    Restarting,
    Detached,
    Stopped
};

pub const Row = struct {
    id: []const u8,
    namespace: []const u8,
    command: []const u8,
    location: []const u8,
    pid: []const u8,
    status: []const u8,
    memory: []const u8,
    cpu: []const u8,
    runtime: []const u8,
    child: bool,
    header: bool,
    table: *Table,

    pub fn init(table: *Table) Row {
        return Row {
            .id = "",
            .namespace = "",
            .command = "",
            .location = "",
            .pid = "",
            .status = "",
            .memory = "",
            .cpu = "",
            .runtime = "",
            .child = false,
            .header = false,
            .table = table,
        };
    }

    pub fn deinit(self: *Row) void {
        if (self.header) {
            return;
        }
        util.gpa.free(self.id);
        util.gpa.free(self.namespace);
        util.gpa.free(self.command);
        util.gpa.free(self.location);
        util.gpa.free(self.pid);
        util.gpa.free(self.status);
        util.gpa.free(self.memory);
        util.gpa.free(self.cpu);
        util.gpa.free(self.runtime);
    }
};

const RowWidths = struct {
    id: usize = 0,
    namespace: usize = 0,
    command: usize = 0,
    location: usize = 0,
    pid: usize = 0,
    status: usize = 0,
    memory: usize = 0,
    cpu: usize = 0,
    runtime: usize = 0,
};

pub const Table = GenerateTableType(Row, RowWidths);

pub const TableMethods = struct {
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

    fn get_proc_status(task: *Task, some_proc: ?*Process) Errors![]const u8 {
        const status = try get_enum_proc_status(task, some_proc);
        return switch (status) {
            ProcStatus.Headless => try util.colour_string("Headless", 204, 0, 0),
            ProcStatus.Running => try util.colour_string("Running", 0, 204, 102),
            ProcStatus.Restarting => try util.colour_string("Restarting", 204, 102, 0),
            ProcStatus.Detached => return try util.colour_string("Detached", 204, 102, 0),
            ProcStatus.Stopped => try util.colour_string("Stopped", 204, 0, 0)
        };
    }

    /// Taking a task and converting it into adding table rows
    /// main row with the task, and secondary rows with each process
    pub fn add_task(self: *Table, task: *Task) Errors!void {
        try append_main_row(
            self, task, if (task.process == null) null else &task.process.?, false
        );

        if (task.process == null) return;

        if (!task.process.?.proc_exists()) {
            const saved_procs = try taskproc.get_running_saved_procs(&task.process.?);
            defer util.gpa.free(saved_procs);
            if (saved_procs.len == 0) {
                return;
            }
            if (!self.show_all) {
                var trunced_proc_count = saved_procs.len;
                const status = try get_enum_proc_status(task, &task.process.?);
                if (status != ProcStatus.Detached) {
                    trunced_proc_count = trunced_proc_count - 1;
                }
                try append_trunced_processes(self, trunced_proc_count);
            } else {
                for (0..saved_procs.len) |i| {
                    var sproc: Process = saved_procs[i];
                    try append_main_row(self, task, &sproc, true);
                }
            }
        } else {
            if (!self.show_all) {
                var proc_len = util.get_map_length(
                    std.AutoHashMap(Pid, f64), task.resources.?.cpu
                );
                const status = try get_enum_proc_status(task, &task.process.?);
                if (status != ProcStatus.Detached) {
                    proc_len = proc_len - 1;
                }
                if (proc_len > 0) {
                    try append_trunced_processes(self, proc_len);
                }
            } else {
                if (task.process.?.children != null) {
                    for (0..task.process.?.children.?.len) |i| {
                        var child: Process = task.process.?.children.?[i];
                        try append_main_row(self, task, &child, true);
                    }
                }
            }
        }
    }

    /// Appending the top headers
    pub fn append_header(self: *Table) Errors!void {
        var row = Row.init(self);
        row.header = true;
        row.id = "id";
        row.namespace = "namespace";
        row.command = "command";
        row.location = "location";
        row.pid = "pid";
        row.status = "status";
        row.memory = "memory";
        row.cpu = "cpu";
        row.runtime = "runtime";
        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
    }

    /// Add a row like " + 2 more processes"
    /// Meant to go underneath when you append a task row
    pub fn append_trunced_processes(
        self: *Table, proc_amount: usize
    ) Errors!void {
        var row = Row.init(self);

        row.command = std.fmt.allocPrint(
            util.gpa, " + {d} more process{s}", .{
                proc_amount, if (proc_amount != 1) "es" else ""
            }) catch |err| return e.verbose_error(
            err, error.FailedAppendTableRow
            );

        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
    }

    /// Appending task row to the table
    /// if the child flag is true, it instead adds a child process under the task
    pub fn append_main_row(
        self: *Table, task: *Task, some_proc: ?*Process, child: bool
    ) Errors!void {
        var row = Row.init(self);

        if (!child) {
            row.id = std.fmt.allocPrint(util.gpa, "{d}", .{task.id})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

            row.namespace = if (task.namespace == null)
                std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow)
                else
                    std.fmt.allocPrint(util.gpa, "{s}", .{task.namespace.?})
                        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

                row.command = if (task.stats.?.command.len > 32)
                    std.fmt.allocPrint(util.gpa, "{s}...", .{task.stats.?.command[0..29]})
                    catch |err| return e.verbose_error(err, error.FailedAppendTableRow)
                    else
                        std.fmt.allocPrint(util.gpa, "{s}", .{task.stats.?.command})
                            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        } else {
            row.id = util.gpa.alloc(u8, 0)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

            row.namespace = util.gpa.alloc(u8, 0)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

            const exe = try some_proc.?.get_exe();
            defer util.gpa.free(exe);
            // This truncates wide strings from windows funcs
            row.command = if (exe.len > 32)
                std.fmt.allocPrint(util.gpa, "{s}...", .{exe[0..29]})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow)
                else
                    std.fmt.allocPrint(util.gpa, "{s}", .{exe})
                        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }

        if (task.stats.?.cwd.len > 24) {
            const concat_str = task.stats.?.cwd[(task.stats.?.cwd.len - 21)..(task.stats.?.cwd.len)];
            row.location = std.fmt.allocPrint(
                util.gpa, "...{s}",
                .{concat_str}
            ) catch |err| return e.verbose_error(
            err, error.FailedAppendTableRow
            );
        } else {
            row.location = std.fmt.allocPrint(util.gpa, "{s}", .{task.stats.?.cwd})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }

        if (some_proc == null or !some_proc.?.proc_exists()) {
            row.pid = std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            row.status = try get_proc_status(task, some_proc);
            row.memory = std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            row.cpu = std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            row.runtime = std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
            self.rows.append(row)
                catch |err| return e.verbose_error(
                    err, error.FailedAppendTableRow
                );
            try self.update_row_widths(&row);
            return;
        }

        var proc = some_proc.?;
        row.pid = std.fmt.allocPrint(util.gpa, "{d}", .{proc.pid})
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        row.status = try get_proc_status(task, proc);

        const memory_str = try util.get_readable_memory(try proc.get_memory());
        row.memory = memory_str;

        const cpu_int = task.resources.?.cpu.get(proc.pid);
        if (cpu_int == null) {
            row.cpu = std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        } else {
            const cpu_perc_str = try util.get_readable_cpu_usage(cpu_int.?);
            row.cpu = cpu_perc_str;
        }

        const runtime_str = try util.get_readable_runtime(try proc.get_runtime());
        row.runtime = runtime_str;

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
        row.command = std.fmt.allocPrint(util.gpa, "Error", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.location = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.pid = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.status = try util.colour_string("Corrupted", 148, 0, 211);
        row.memory = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.cpu = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        row.runtime = std.fmt.allocPrint(util.gpa, "N/A", .{})
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
        self.corrupted_rows = true;
    }
};


test "lib/table/main.zig" {
    std.debug.print("\n--- lib/table/main.zig ---\n", .{});
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
        false
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

    // const width: usize = if (builtin.os.tag == .windows) 81 else 82;
    // try expect(table.get_total_row_width() == width);

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
    row.namespace = try std.fmt.allocPrint(util.gpa, "nsone", .{});
    row.command = try std.fmt.allocPrint(util.gpa, "test_command", .{});
    row.location = try std.fmt.allocPrint(util.gpa, "test_location", .{});
    row.pid = try std.fmt.allocPrint(util.gpa, "12345", .{});
    row.status = try util.colour_string("Running", 0, 204, 102);
    row.memory = try std.fmt.allocPrint(util.gpa, "1234 MiB", .{});
    row.cpu = try std.fmt.allocPrint(util.gpa, "100.00", .{});
    row.runtime = try std.fmt.allocPrint(util.gpa, "0h 0m 1s", .{});
    try table.rows.append(row);
    try table.update_row_widths(&row);

    try expect(table.row_widths.id == "id".len + 2);
    try expect(table.row_widths.namespace == "namespace".len + 2);
    try expect(table.row_widths.command == "test_command".len + 2);
    try expect(table.row_widths.location == "test_location".len + 2);
    try expect(table.row_widths.pid == "12345".len + 2);
    try expect(table.row_widths.status == "Running".len + 2);
    try expect(table.row_widths.memory == "1234 MiB".len + 2);
    try expect(table.row_widths.cpu == "100.00".len + 2);
    try expect(table.row_widths.runtime == "0h 0m 1s".len + 2);

    const total_width = table.get_total_row_width();
    const expected_total_width = "| id | namespace | test_command | test_location | 12345 | Running | 1234 MiB | 100.00 | 0h 0m 1s |".len;
    try expect(total_width == expected_total_width);
    const fl_row_width: f32 = @floatFromInt(total_width);

    const row_count = table.rows.items.len + 3;
    const window_cols = 100;
    const total_rows = Table.calculate_total_rows(fl_row_width, window_cols, row_count);
    const table_string = 
        \\+------------------------------------------------------------------------------------------------+
        \\| id | namespace | command      | location      | pid   | status  | memory   | cpu    | runtime  |
        \\+------------------------------------------------------------------------------------------------+
        \\| 1  | nsone     | test_command | test_location | 12345 | Running | 1234 MiB | 100.00 | 0h 0m 1s |
        \\+------------------------------------------------------------------------------------------------+
        \\
    ;
    const new_lines = std.mem.count(u8, table_string, "\n");

    try expect(new_lines == total_rows);
}

