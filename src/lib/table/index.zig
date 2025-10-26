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

const m = @import("./main.zig");
const MainRow = m.Row;
const MainRowWidths = m.RowWidths;

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

/// Because there are multiple table types, the main one and the stats, this
/// dynamically generates the type for either:
/// const Table = GenerateTableType(MainRow, MainRowWidths);
/// const table = Table.init(true);
pub fn GenerateTableType(
    comptime Row: type,
    comptime RowWidths: type,
) type {
    return struct {
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
        ) Errors!Self {
            const rows = std.ArrayList(Row).init(util.gpa);
            const table = Self {
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

        pub fn remove_rows(self: *Self, num_rows: usize) Errors!void {
            for (0..num_rows) |_| {
                self.rows.items[self.rows.items.len - 1].deinit();
                _ = self.rows.swapRemove(self.rows.items.len - 1);
            }
        }

        fn refresh_all_row_widths(self: *Self) Errors!void {
            for (self.rows.items) |*row| {
                try self.update_row_widths(row);
            }
        }

        /// Iterates over every field and updates row widths to make it responsive
        pub fn update_row_widths(self: *Self, new_row: *Row) Errors!void {
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

        pub fn get_total_row_width(self: *Self) usize {
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
    };
}

test "lib/table/index.zig" {
    std.debug.print("\n--- lib/table/index.zig ---\n", .{});
}
