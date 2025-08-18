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

const Row = struct {
    id: []const u8,
    namespace: []const u8,
    command: []const u8,
    location: []const u8,
    pid: []const u8,
    status: []const u8,
    memory: []const u8,
    cpu: []const u8,
    runtime: []const u8,
    monitoring: []const u8,
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
            .monitoring = "",
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
        util.gpa.free(self.monitoring);
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
    monitoring: usize = 0,
};
const Separators = struct {
    const Chars = struct { left: []const u8, right: []const u8, separator: []const u8 };

    const top = Chars{
        .left = "+",
        .right = "+",
        .separator = "+",
    };

    const bottom = Chars{
        .left = "+",
        .right = "+",
        .separator = "+",
    };

    const middle = Chars{
        .left = "+",
        .right = "+",
        .separator = "+",
    };

    const hori_line = "-";
    const vert_line = "|";

    // These cool unicode separators cause gibberish on some terminals
    // so I'll keep them commented until I can include them on non utf8 terminals
    // const top = Chars{
    //     .left = "┌",
    //     .right = "┐",
    //     .separator = "┬",
    // };

    // const bottom = Chars{
    //     .left = "└",
    //     .right = "┘",
    //     .separator = "┴",
    // };

    // const middle = Chars{
    //     .left = "├",
    //     .right = "┤",
    //     .separator = "┼",
    // };

    // const hori_line = "─";
    // const vert_line = "│";
};
pub const Table = struct {
    const Self = @This();

    const ProcStatus = enum {
        Headless,
        Running,
        Restarting,
        Detached,
        Stopped
    };

    row_widths: RowWidths,
    rows: std.ArrayList(Row),
    show_all: bool,
    corrupted_rows: bool = false,

    pub fn init(
        show_all: bool
    ) Errors!Table {
        const rows = std.ArrayList(Row).init(util.gpa);
        const table = Table {
            .rows = rows,
            .row_widths = RowWidths{},
            .show_all = show_all
        };
        return table;
    }

    pub fn deinit(self: *Self) void {
        for (self.rows.items) |*it| {
            if (!it.header) {
                it.deinit();
            }
        }
        self.rows.clearAndFree();
        self.rows.clearRetainingCapacity();
        self.rows.deinit();
    }

    /// Taking a task and converting it into adding table rows
    /// main row with the task, and secondary rows with each process
    pub fn add_task(self: *Self, task: *Task) Errors!void {
        try self.append_main_row(
            task, if (task.process == null) null else &task.process.?, false
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
                try self.append_trunced_processes(trunced_proc_count);
            } else {
                for (0..saved_procs.len) |i| {
                    var sproc: Process = saved_procs[i];
                    try self.append_main_row(task, &sproc, true);
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
                    try self.append_trunced_processes(proc_len);
                }
            } else {
                if (task.process.?.children != null) {
                    for (0..task.process.?.children.?.len) |i| {
                        var child: Process = task.process.?.children.?[i];
                        try self.append_main_row(task, &child, true);
                    }
                }
            }
        }
    }

    /// Appending the top headers
    pub fn append_header(self: *Self) Errors!void {
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
        row.monitoring = "monitoring";
        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
    }

    /// Add a row like " + 2 more processes"
    /// Meant to go underneath when you append a task row
    pub fn append_trunced_processes(
        self: *Self, proc_amount: usize
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
        self: *Self, task: *Task, some_proc: ?*Process, child: bool
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

            row.monitoring = if (task.stats.?.monitoring == .Deep)
                std.fmt.allocPrint(util.gpa, "deep", .{})
                    catch |err| return e.verbose_error(err, error.FailedAppendTableRow)
            else 
                std.fmt.allocPrint(util.gpa, "shallow", .{})
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

            row.monitoring = util.gpa.alloc(u8, 0)
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

    pub fn remove_rows(self: *Self, num_rows: usize) Errors!void {
        for (0..num_rows) |_| {
            self.rows.items[self.rows.items.len - 1].deinit();
            _ = self.rows.swapRemove(self.rows.items.len - 1);
        }
    }

    /// Inserting an erroneous row for when a task is missing some things
    /// likely due to corruption
    pub fn add_corrupted_task(self: *Self, task_id: TaskId) Errors!void {
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

    fn refresh_all_row_widths(self: *Self) Errors!void {
        for (self.rows.items) |*row| {
            try self.update_row_widths(row);
        }
    }

    /// Iterates over every field and updates row widths to make it responsive
    fn update_row_widths(self: *Self, new_row: *Row) Errors!void {
        inline for (@typeInfo(RowWidths).@"struct".fields) |field| {
            // Adding a space of padding on either side
            const new_field = try util.get_string_visual_length(
                @field(new_row, field.name)
            ) + 2;
            const old_field = @field(self.row_widths, field.name);
            if (old_field < new_field) {
                @field(self.row_widths, field.name) = new_field;
            }
        }
    }

    /// Prints all headers and rows in the table
    pub fn print_table(self: *Self) Errors!void {
        try self.print_border(Separators.top);
        for (self.rows.items) |row| {
            try self.print_row(&row);
            if (row.header) {
                try self.print_border(Separators.middle);
            }
        }
        try self.print_border(Separators.bottom);
    }

    fn print_row(self: *Self, row: *const Row) Errors!void {
        var buf_list = std.ArrayList(u8).init(util.gpa);
        defer buf_list.deinit();
        var writer = buf_list.writer();

        for (Separators.vert_line) |byte| {
            writer.writeByte(byte)
                catch |err| return e.verbose_error(err, error.FailedToPrintTable);
        }

        inline for (@typeInfo(RowWidths).@"struct".fields, 0..) |field, i| {
            writer.writeByte(' ')
                catch |err| return e.verbose_error(err, error.FailedToPrintTable);
            const row_width = @field(row, field.name).len;
            const visual_row_width = try util.get_string_visual_length(
                @field(row, field.name)
            );
            // -1 because left padding has already been added
            for (0..row_width) |j| {
                writer.writeByte(@field(row, field.name)[j])
                    catch |err| return e.verbose_error(err, error.FailedToPrintTable);
            }
            // Adding right padding
            for (visual_row_width..(@field(self.row_widths, field.name) - 1)) |_| {
                writer.writeByte(' ')
                    catch |err| return e.verbose_error(err, error.FailedToPrintTable);
            }

            if (i != @typeInfo(RowWidths).@"struct".fields.len - 1) {
                for (Separators.vert_line) |byte| {
                    writer.writeByte(byte)
                        catch |err| return e.verbose_error(err, error.FailedToPrintTable);
                }
            }
        }

        for (Separators.vert_line) |byte| {
            writer.writeByte(byte)
                catch |err| return e.verbose_error(err, error.FailedToPrintTable);
        }

        try log.print("{s}\n", .{buf_list.items});
    }

    fn print_border(self: *Self, chars: Separators.Chars) Errors!void {
        var buf_list = std.ArrayList(u8).init(util.gpa);
        defer buf_list.deinit();
        var writer = buf_list.writer();

        for (chars.left) |byte| {
            writer.writeByte(byte)
                catch |err| return e.verbose_error(err, error.FailedToPrintTable);
        }

        inline for (@typeInfo(RowWidths).@"struct".fields, 0..) |field, i| {
            for (0..@field(self.row_widths, field.name)) |_| {
                for (Separators.hori_line) |byte| {
                    writer.writeByte(byte)
                        catch |err| return e.verbose_error(err, error.FailedToPrintTable);
                }
            }

            if (i != @typeInfo(RowWidths).@"struct".fields.len - 1) {
                for (chars.separator) |byte| {
                    writer.writeByte(byte)
                        catch |err| return e.verbose_error(err, error.FailedToPrintTable);
                }
            }
        }

        for (chars.right) |byte| {
            writer.writeByte(byte)
                catch |err| return e.verbose_error(err, error.FailedToPrintTable);
        }
        try log.print("{s}\n", .{buf_list.items});
    }

    fn get_total_row_width(self: *Self) usize {
        const fields = @typeInfo(RowWidths).@"struct".fields;

        // Borders in between
        var total_width: usize = fields.len + 1;
        inline for (fields) |field| {
            total_width += @field(self.row_widths, field.name);
        }
        return total_width;
    }

    /// Clears the printed table
    pub fn clear(self: *Self) Errors!void {
        const num_of_rows = self.rows.items.len + 3;
        // Length of table row in terminal columns
        const fl_row_width: f32 = @floatFromInt(self.get_total_row_width());
        const fl_window_cols: f32 = @floatFromInt(try window.get_window_cols());

        const total_rows_printed = calculate_total_rows(fl_row_width, fl_window_cols, num_of_rows);

        // VT100 go up 1 line and erase it
        for (0..total_rows_printed) |_| try log.print("\x1b[A\x1b[2K", .{});
    }

    pub fn calculate_total_rows(row_width: f32, window_cols: f32, num_of_rows: usize) usize {
        const overlap: usize = if (window_cols < row_width)
            @intFromFloat(@ceil(row_width / window_cols))
        else
            1;

        // +2 for the top and bottom borders
        const total_rows_printed: usize = (num_of_rows * overlap);
        return total_rows_printed;
    }

    pub fn reset(self: *Self) void {
        for (self.rows.items) |*it| {
            if (!it.header) {
                it.deinit();
            }
        }
        self.rows.clearAndFree();
        self.rows.clearRetainingCapacity();
        self.row_widths = RowWidths{};
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
};

test "lib/table/index.zig" {
    std.debug.print("\n--- lib/table/index.zig ---\n", .{});
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
        .Shallow
    );
    defer {
        new_task.delete() catch @panic("Failed to delete task.");
        new_task.deinit();
    }

    var table = try Table.init(false);
    defer table.deinit();
    try table.add_task(&new_task);
    try expect(table.rows.items.len == 1);
    try expect(table.corrupted_rows == false);

    const width: usize = if (builtin.os.tag == .windows) 91 else 92;
    try expect(table.get_total_row_width() == width);

    table.reset();

    try expect(table.rows.items.len == 0);
}

test "Validating row count for clearing" {
    std.debug.print("Validating row count for clearing\n", .{});

    var table = try Table.init(false);
    defer table.deinit();
    try table.append_header();
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
    row.monitoring = try std.fmt.allocPrint(util.gpa, "deep", .{});
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
    try expect(table.row_widths.monitoring == "monitoring".len + 2);

    const total_width = table.get_total_row_width();
    const expected_total_width = "| id | namespace | test_command | test_location | 12345 | Running | 1234 MiB | 100.00 | 0h 0m 1s | monitoring |".len;
    try expect(total_width == expected_total_width);
    const fl_row_width: f32 = @floatFromInt(total_width);

    const row_count = table.rows.items.len + 3;
    const window_cols = 100;
    const total_rows = Table.calculate_total_rows(fl_row_width, window_cols, row_count);
    const table_string = 
        \\+-------------------------------------------------------------------------------------------------------------
        \\+
        \\| id | namespace | command      | location      | pid   | status  | memory   | cpu    | runtime  | monitoring 
        \\|
        \\+-------------------------------------------------------------------------------------------------------------
        \\+
        \\| 1  | nsone     | test_command | test_location | 12345 | Running | 1234 MiB | 100.00 | 0h 0m 1s | monitoring 
        \\|
        \\+-------------------------------------------------------------------------------------------------------------
        \\+
        \\
    ;
    const new_lines = std.mem.count(u8, table_string, "\n");

    try expect(new_lines == total_rows);
}
