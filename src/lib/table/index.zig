const std = @import("std");
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
    // but I'll keep them until I can include them on non ut8 terminals
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
                try self.append_trunced_processes(saved_procs.len - 1);
            } else {
                for (0..saved_procs.len) |i| {
                    var sproc: Process = saved_procs[i];
                    try self.append_main_row(task, &sproc, true);
                }
            }
        } else {
            if (!self.show_all) {
                const proc_len = util.get_map_length(
                    std.AutoHashMap(Pid, f64), task.resources.cpu
                );
                if (
                    proc_len > 0 and
                    proc_len - 1 > 0 // Minus the main process
                ) {
                    try self.append_trunced_processes(proc_len - 1);
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
        } else {
            row.id = util.gpa.alloc(u8, 0)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }

        if (!child) {
            row.namespace = if (task.namespace == null)
                std.fmt.allocPrint(util.gpa, "N/A", .{})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow)
            else
                std.fmt.allocPrint(util.gpa, "{s}", .{task.namespace.?})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        } else {
            row.namespace = util.gpa.alloc(u8, 0)
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        }

        if (!child) {
            row.command = if (task.stats.command.len > 32)
                std.fmt.allocPrint(util.gpa, "{s}...", .{task.stats.command[0..29]})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow)
            else
                std.fmt.allocPrint(util.gpa, "{s}", .{task.stats.command})
                catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
        } else {
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

        if (task.stats.cwd.len > 24) {
            const concat_str = task.stats.cwd[(task.stats.cwd.len - 21)..(task.stats.cwd.len)];
            row.location = std.fmt.allocPrint(
                util.gpa, "...{s}",
                .{concat_str}
            ) catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        } else {
            row.location = std.fmt.allocPrint(util.gpa, "{s}", .{task.stats.cwd})
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

        const cpu_int = task.resources.cpu.get(proc.pid);
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
    pub fn clear(self: *Self, num_of_rows: usize) Errors!void {
        // Length of table row in terminal columns
        const fl_row_width: f32 = @floatFromInt(self.get_total_row_width());
        const fl_window_cols: f32 = @floatFromInt(try window.get_window_cols());
        const overlap: usize = if (fl_window_cols < fl_row_width)
            @intFromFloat(@ceil(fl_row_width / fl_window_cols))
        else
            1;

        const total_rows_printed: usize = num_of_rows * overlap;

        // VT100 go up 1 line and erase it
        for (0..total_rows_printed) |_| try log.print("\x1b[A\x1b[2K", .{});
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

    fn get_proc_status(task: *Task, some_proc: ?*Process) Errors![]const u8 {
        if (some_proc != null) {
            var proc = some_proc.?;
            // Does inner process exist
            if (proc.proc_exists()) {
                if (task.daemon == null or !task.daemon.?.proc_exists()) {
                    return try util.colour_string("Headless", 204, 0, 0);
                }
                return try util.colour_string("Running", 0, 204, 102);
            }
            if (task.daemon != null and task.daemon.?.proc_exists() and task.stats.persist) {
                // The child command hasn't been run but the parent task proc is waiting
                return try util.colour_string("Restarting", 204, 102, 0);
            }
            const saved_procs = try taskproc.get_running_saved_procs(proc);
            defer util.gpa.free(saved_procs);
            if (saved_procs.len != 0) {
                return try util.colour_string("Detached", 204, 102, 0);
            }
        }
        return try util.colour_string("Stopped", 204, 0, 0);
    }
};
