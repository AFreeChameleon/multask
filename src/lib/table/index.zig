const std = @import("std");
const Process = @import("../task/process.zig").Process;

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
        self.rows.deinit();
    }

    /// Taking a task and converting it into adding table rows
    /// main row with the task, and secondary rows with each process
    pub fn add_task(self: *Self, task: *Task) Errors!void {
        try self.append_main_row(task, &task.process, false);

        if (task.process.proc_exists()) {
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
                return;
            }

            // Getting child PIDs from the CPU usage stats
            var pid_itr = task.resources.cpu.iterator();
            while (pid_itr.next()) |item| {
                const pid = item.key_ptr.*;
                if (task.process.get_pid() == pid)
                    continue;
                var process = try Process.init(pid, task);
                try self.append_main_row(task, &process, true);
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
        var buf: [Lengths.MEDIUM]u8 = undefined;

        row.command = try util.strdup(std.fmt.bufPrint(
            &buf, " + {d} more process{s}", .{
                proc_amount, if (proc_amount != 1) "es" else ""
        }) catch |err| return e.verbose_error(
            err, error.FailedAppendTableRow
        ), error.FailedAppendTableRow);

        self.rows.append(row)
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
        try self.update_row_widths(&row);
    }

    /// Appending task row to the table
    /// if the child flag is true, it instead adds a child process under the task
    pub fn append_main_row(
        self: *Self, task: *Task, proc: *Process, child: bool
    ) Errors!void {
        var buf: [Lengths.MEDIUM]u8 = undefined;

        var row = Row.init(self);
        if (!child) {
            row.id = try util.strdup(std.fmt.bufPrint(&buf, "{d}", .{task.id})
                catch |err| return e.verbose_error(
                    err, error.FailedAppendTableRow
            ), error.FailedAppendTableRow);
        } else {
            row.id = "";
        }

        if (!child) {
            row.namespace = if (task.namespace == null)
                "N/A"
            else
                task.namespace.?;
        } else {
            row.namespace = "";
        }

        if (!child) {
            const command = if (task.stats.command.len > 32)
                task.stats.command[0..29] ++ "..."
            else
                task.stats.command;
            row.command = try util.strdup(command, error.FailedAppendTableRow);
        } else {
            const exe = try proc.get_exe();
            // This truncates wide strings from windows funcs
            const trim_exe = if (exe.len > 32)
                exe[0..29] ++ "..."
            else
                exe;
            row.command = try util.strdup(trim_exe, error.FailedAppendTableRow);
        }

        buf = std.mem.zeroes([Lengths.MEDIUM]u8);
        var cwd = task.stats.cwd;
        if (task.stats.cwd.len > 24) {
            const new_cwd = std.fmt.bufPrint(
                &buf, "...{s}",
                .{task.stats.cwd[(task.stats.cwd.len - 21)..(task.stats.cwd.len)]
            }) catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            );
            cwd = try util.strdup(new_cwd, error.FailedAppendTableRow);
        }
        row.location = try util.strdup(cwd, error.FailedAppendTableRow);

        if (!proc.proc_exists()) {
            row.pid = "N/A";
            row.status = try get_proc_status(task, proc);
            row.memory = "N/A";
            row.cpu = "N/A";
            row.runtime = "N/A";
            self.rows.append(row)
                catch |err| return e.verbose_error(
                    err, error.FailedAppendTableRow
            );
            try self.update_row_widths(&row);
            return;
        }

        row.pid = try util.strdup(std.fmt.bufPrint(&buf, "{d}", .{proc.get_pid()})
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
            ), error.FailedAppendTableRow);
        row.status = try get_proc_status(task, proc);

        const memory_str = try util.get_readable_memory(try proc.get_memory());
        row.memory = memory_str;

        const cpu_int = task.resources.cpu.get(proc.get_pid());
        if (cpu_int == null) {
            row.cpu = "N/A";
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
        var buf: [Lengths.MEDIUM]u8 = undefined;
        var row = Row.init(self);
        row.id = try util.strdup(std.fmt.bufPrint(&buf, "{d}", .{task_id})
            catch |err| return e.verbose_error(
                err, error.FailedAppendTableRow
        ), error.FailedAppendTableRow);
        row.command = "Error";
        row.location = "N/A";
        row.pid = "N/A";
        row.status = try util.colour_string("Corrupted", 148, 0, 211);
        row.memory = "N/A";
        row.cpu = "N/A";
        row.runtime = "N/A";
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
    pub fn clear(self: *Self) Errors!void {
        // Top & bottom border and separator of header
        const num_of_rows = self.rows.items.len + 3;

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
        self.rows.clearAndFree();
        self.row_widths = RowWidths{};
    }

    fn get_proc_status(task: *Task, proc: *Process) Errors![]const u8 {
        // Does inner process exist
        if (proc.proc_exists()) {
            var task_proc = try Process.init(task.pid, task);
            if (!task_proc.proc_exists()) {
                return try util.colour_string("Detached", 204, 0, 0);
            }
            return try util.colour_string("Running", 0, 204, 102);
        }
        var task_proc = try Process.init(task.pid, task);
        if (task_proc.proc_exists() and task.stats.persist) {
            // The child command hasn't been run but the parent task proc is waiting
            return try util.colour_string("Restarting", 204, 102, 0);
        }
        return try util.colour_string("Stopped", 204, 0, 0);
    }
};
