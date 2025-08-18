const std = @import("std");
const expect = std.testing.expect;
const e = @import("../error.zig");
const Errors = e.Errors;

const util = @import("../util.zig");
const FlagType = enum(u2){
    value,
    static
};

pub const Flag = struct {
    type: FlagType,
    value: ?[]const u8 = null,
    name: u8,
    long_name: ?[]const u8 = null,
    exists: bool = false
};

const CaptureMode = enum(u2) {
    arg,
    value,
    arg_perm // Everything after the --
};

const ArgFound = struct {
    capture_mode: CaptureMode,
    arg_char: u8
};

pub fn get_slice_args() Errors![][]u8 {
    const argv = std.process.argsAlloc(util.gpa)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    defer std.process.argsFree(util.gpa, argv);

    var new_argv = util.gpa.alloc([]u8, argv.len)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);

    for (argv, 0..) |arg, i| {
        new_argv[i] = try util.strdup(@as([]u8, arg), error.ParsingCommandArgsFailed);
    }

    return new_argv;
}

/// Assigning values to each flag don't need to free each value since its taken from args
pub fn parse_args(args: [][]u8, flags: []Flag) Errors![][]u8 {
    var capture_mode: CaptureMode = .arg;
    var capturing: ?u8 = null;
    var values = std.ArrayList([]u8).init(util.gpa);
    defer values.deinit();
    for (args) |arg| {
        // == .arg because it can't be arg_perm since that now can't be changed
        if (capture_mode == .arg and arg.len > 0 and arg[0] == '-') {
            // Parsing flags like --onearg
            if (arg.len > 2 and arg[1] == '-') {
                const res = try find_long_arg(arg[2..], flags);
                if (res != null) {
                    capture_mode = res.?.capture_mode;
                    capturing = res.?.arg_char;
                } else {
                    values.append(arg)
                        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
                }
                continue;
            // Triggering the -- as an argument to make anything else after an arg
            } else if (arg.len == 2 and arg[1] == '-') {
                capture_mode = .arg_perm;
                continue;
            // Parsing flags like -abc
            } else {
                const res = try find_short_args(arg[1..], flags);
                if (res != null) {
                    capture_mode = res.?.capture_mode;
                    capturing = res.?.arg_char;
                }
                continue;
            }
        }
        if (capture_mode == .value) {
            if (capturing == null) {
                return error.ParsingCommandArgsFailed;
            }
            for (flags) |*flag| {
                if (flag.name == capturing.?) {
                    flag.value = arg;
                    break;
                }
            }
            capture_mode = .arg;
            capturing = null;
            continue;
        }
        if (capture_mode == .arg or capture_mode == .arg_perm) {
            values.append(arg)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
            continue;
        }
    }
    if (capture_mode == .value) {
        return error.MissingArgumentValue;
    }
    return values.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
}

fn find_long_arg(arg: []u8, flags: []Flag) Errors!?ArgFound {
    for (flags) |*flag| {
        if (flag.long_name != null and std.mem.eql(u8, arg, flag.long_name.?)) {
            if (flag.type == .value) {
                flag.exists = true;
                return ArgFound {
                    .capture_mode = .value,
                    .arg_char = flag.name
                };
            } else {
                flag.exists = true;
                return null;
            }
        }
    }
    return null;
}

fn find_short_args(arg_string: []u8, flags: []Flag) Errors!?ArgFound {
    for (arg_string, 0..) |char, i| {
        var found_arg = false;
        for (flags) |*flag| {
            if (char == flag.name) {
                found_arg = true;
                if (flag.type == .value) {
                    if (i != arg_string.len - 1) {
                        return error.MissingArgumentValue;
                    }
                    flag.exists = true;
                    return ArgFound {
                        .capture_mode = .value,
                        .arg_char = char
                    };
                }
                if (flag.type == .static) {
                    flag.exists = true;
                }
            }
        }
        if (!found_arg) {
            return error.InvalidOption;
        }
    }
    return null;
}

test "lib/args/parse.zig" {
    std.debug.print("\n--- lib/args/parse.zig ---\n", .{});
}

test "Parsing -a which exists" {
    std.debug.print("Parsing -a which exists\n", .{});
    var flags = try util.gpa.alloc(Flag, 1);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .static,
        .name = 'a'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const args1 = try std.fmt.allocPrint(util.gpa, "-a", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const vals = try parse_args(args.items, flags);
    defer util.gpa.free(vals);

    try expect(vals.len == 0);
    try expect(flags[0].exists);
}

test "Parsing -b which does not exist to get InvalidOption" {
    std.debug.print("Parsing -b which does not exist to get InvalidOption\n", .{});
    var flags = try util.gpa.alloc(Flag, 1);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .static,
        .name = 'a'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const args1 = try std.fmt.allocPrint(util.gpa, "-b", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const vals = parse_args(args.items, flags) catch |err| switch (err) {
        error.InvalidOption => return,
        else => return err
    };
    defer util.gpa.free(vals);
    try expect(vals.len == 0);
}

test "Parsing -a with a value" {
    std.debug.print("Parsing -a with a value\n", .{});
    var flags = try util.gpa.alloc(Flag, 1);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .value,
        .name = 'a'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const args1 = try std.fmt.allocPrint(util.gpa, "-a", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "testval", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    _ = try parse_args(args.items, flags);
    try expect(std.mem.eql(u8, flags[0].value.?, "testval"));
}

test "Parsing -a without a value to get MissingArgumentValue" {
    std.debug.print("Parsing -a without a value to get MissingArgumentValue\n", .{});
    var flags = try util.gpa.alloc(Flag, 1);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .value,
        .name = 'a'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();
    const args1 = try std.fmt.allocPrint(util.gpa, "args", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "-a", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    _ = parse_args(args.items, flags) catch |err| switch (err) {
        error.MissingArgumentValue => return,
        else => return err
    };
    try expect(false);
}

test "Parsing --arg-one with a value" {
    std.debug.print("Parsing --arg-one with a value\n", .{});
    var flags = try util.gpa.alloc(Flag, 1);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .value,
        .name = 'a',
        .long_name = "arg-one"
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();
    const args1 = try std.fmt.allocPrint(util.gpa, "--arg-one", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "testval", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    _ = try parse_args(args.items, flags);
    try expect(std.mem.eql(u8, flags[0].value.?, "testval"));
}

test "Parsing -ab with a value" {
    std.debug.print("Parsing -ab with a value\n", .{});
    var flags = try util.gpa.alloc(Flag, 2);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .static,
        .name = 'a'
    };
    flags[1] = Flag {
        .type = .value,
        .name = 'b'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const args1 = try std.fmt.allocPrint(util.gpa, "-ab", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "testval", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    _ = try parse_args(args.items, flags);
    try expect(flags[0].exists);
    try expect(std.mem.eql(u8, flags[1].value.?, "testval"));
}

test "Parsing -ab with a value out of order to get MissingArgumentValue" {
    std.debug.print("Parsing -ab with a value out of order to get MissingArgumentValue\n", .{});
    var flags = try util.gpa.alloc(Flag, 2);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .value,
        .name = 'a'
    };
    flags[1] = Flag {
        .type = .static,
        .name = 'b'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const args1 = try std.fmt.allocPrint(util.gpa, "-ab", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "testval", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    _ = parse_args(args.items, flags) catch |err| switch (err) {
        error.MissingArgumentValue => return,
        else => return err
    };
    try expect(false);
}

test "Parsing -a -b with a value" {
    std.debug.print("Parsing -a -b with a value\n", .{});
    var flags = try util.gpa.alloc(Flag, 2);
    defer util.gpa.free(flags);
    flags[0] = Flag {
        .type = .static,
        .name = 'a'
    };
    flags[1] = Flag {
        .type = .value,
        .name = 'b'
    };

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const args1 = try std.fmt.allocPrint(util.gpa, "-a", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "-b", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    const args3 = try std.fmt.allocPrint(util.gpa, "testval", .{});
    defer util.gpa.free(args3);
    try args.append(args3);

    const vals = try parse_args(args.items, flags);
    defer util.gpa.free(vals);
    try expect(flags[0].exists);
    try expect(std.mem.eql(u8, flags[1].value.?, "testval"));
    try expect(vals.len == 0);
}

test "Parsing only values" {
    std.debug.print("Parsing only values\n", .{});
    const flags = try util.gpa.alloc(Flag, 0);
    defer util.gpa.free(flags);

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const vals1 = try std.fmt.allocPrint(util.gpa, "val1", .{});
    defer util.gpa.free(vals1);
    try args.append(vals1);

    const vals2 = try std.fmt.allocPrint(util.gpa, "val 2", .{});
    defer util.gpa.free(vals2);
    try args.append(vals2);

    const vals = try parse_args(args.items, flags);
    defer util.gpa.free(vals);
    try expect(vals.len == 2);
    try expect(std.mem.eql(u8, vals[0], "val1"));
    try expect(std.mem.eql(u8, vals[1], "val 2"));
}

test "Parsing fake arguments" {
    std.debug.print("Parsing fake arguments\n", .{});
    const flags = try util.gpa.alloc(Flag, 0);
    defer util.gpa.free(flags);

    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();
    const args1 = try std.fmt.allocPrint(util.gpa, "--fake=value", .{});
    defer util.gpa.free(args1);
    try args.append(args1);

    const args2 = try std.fmt.allocPrint(util.gpa, "regular-arg", .{});
    defer util.gpa.free(args2);
    try args.append(args2);

    const vals = try parse_args(args.items, flags);
    defer util.gpa.free(vals);

    try expect(vals.len == 2);
    try expect(std.mem.eql(u8, vals[0], "--fake=value"));
    try expect(std.mem.eql(u8, vals[1], "regular-arg"));
}
