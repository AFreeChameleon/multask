const std = @import("std");
const flute = @import("flute");

const e = @import("../error.zig");
const Errors = e.Errors;

pub fn apply_key_val(comptime T: type, row: *T, comptime key: []const u8, comptime val: []const u8) void {
    @memcpy(@field(row, key)[0..val.len], val);
}

pub fn apply_header_val(comptime T: type, row: *T, comptime val: []const u8) void {
    apply_key_val(T, row, val, val);
}

pub fn print_table(comptime T: type, table: *T, writer: anytype) Errors!void {
    table.printBorder(flute.table.Borders.top, writer)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    table.printRow(0, writer)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    table.printBorder(flute.table.Borders.top, writer)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    for (1..table.rows.items.len) |i| {
        var row = table.rows.items[i];
        trim_row(@TypeOf(row), &row);
        table.printRow(i, writer)
            catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
    }
    table.printBorder(flute.table.Borders.top, writer)
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);
}

pub fn trim_row(comptime T: type, row: *T) void {
    inline for (std.meta.fields(T)) |field| {
        const trimmed_value = std.mem.trimRight(
            u8,
            @field(row, field.name),
            &[1]u8{0}
        );
        @field(row, field.name) = @field(row, field.name)[0..trimmed_value.len];
    }
}

pub fn free_table_rows(comptime T: type, table: *T) void {
    const rows_length = table.rows.items.len;
    for (0..rows_length) |_| {
        const row = table.removeRow(0);
        row.deinit();
    }
}

pub fn reset_table(comptime T: type, table: *T) Errors!void {
    const out = std.io.getStdOut();

    var buf = std.io.bufferedWriter(out.writer());
    table.clear(&buf.writer())
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    buf.flush()
        catch |err| return e.verbose_error(err, error.FailedAppendTableRow);

    const rows_length = table.rows.items.len;

    for (0..rows_length) |_| {
        const row = table.removeRow(0);
        row.deinit();
    }
}
