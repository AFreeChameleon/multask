const std = @import("std");
const expect = std.testing.expect;
const unix_fork = @import("../lib/unix/fork.zig");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const tm = @import("../lib/task/manager.zig");
const TaskManager = tm.TaskManager;
const Tasks = tm.Tasks;

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");

const log = @import("../lib/log.zig");
const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    lines: u32,
    watch: bool,
    args: util.TaskArgs,
    help: bool,
};

pub fn run(argv: [][]u8) Errors!void {
    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    var flags = try parse_cmd_args(argv, &tasks);
    defer flags.args.deinit();

    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    const id = flags.args.ids.?[0];
    var task = Task.init(id);
    defer task.deinit();
    try TaskManager.get_task_from_id(&task);
    const last_lines: u32 = if (flags.lines == 0) 20 else flags.lines;
    // Task read last lines
    try log.printinfo("Getting last {d} lines.", .{last_lines});
    try task.files.?.read_last_logs(last_lines);
    if (flags.watch) {
        // Blank new line
        try log.println("", .{});
        try log.printinfo("Listening to new lines...", .{});
        // try log.printdebug("Listening is still buggy - logs don't sync properly.", .{});
        // Task watch future lines by attaching to the /proc/{id}/fd/1 and 2 handles
        try task.files.?.listen_log_files();
    }
}

fn parse_cmd_args(argv: [][]u8, tasks: *Tasks) Errors!Flags {
    var flags = Flags {
        .help = false,
        .lines = 0,
        .watch = false,
        .args = undefined
    };
    var pflags = util.gpa.alloc(parse.Flag, 5)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    defer util.gpa.free(pflags);
    pflags[0] = parse.Flag {
        .name = 'l',
        .type = .value
    };
    pflags[1] = parse.Flag {
        .name = 'w',
        .type = .static
    };
    pflags[2] = parse.Flag {
        .name = 'f',
        .type = .static
    };
    pflags[3] = parse.Flag {
        .name = 'h',
        .type = .static
    };
    pflags[4] = parse.Flag {
        .name = 'd',
        .type = .static
    };

    const vals = try parse.parse_args(argv, pflags);
    defer util.gpa.free(vals);

    for (pflags) |flag| {
        if (!flag.exists) {
            continue;
        }
        switch (flag.name) {
            'l' => {
                flags.lines = std.fmt.parseInt(u32, flag.value.?, 10)
                    catch |err| switch (err) {
                        error.InvalidCharacter => {
                            try log.print_custom_err("Lines must be a number above 1.", .{});
                            return error.ParsingCommandArgsFailed;
                        },
                        else => return error.ParsingCommandArgsFailed
                    };
            },
            'w', 'f' => flags.watch = true,
            'h' => flags.help = true,
            'd' => log.enable_debug(),
            else => continue
        }
    }
    const parsed_args = try util.parse_cmd_vals(vals, tasks);
    flags.args = parsed_args;
    if (vals.len == 0 and !flags.help) {
        flags.args.deinit();
        return error.MissingTaskId;
    }
    if (flags.args.ids.?.len > 1) {
        flags.args.deinit();
        return error.OnlyOneTaskId;
    }
    return flags;
}

pub const help_rows = .{
    .{"mlt logs"},
    .{"Reads logs of the task"},
    .{"Usage: mlt logs -l 1000 -w 1"},
    .{"Flags:"},
    .{"", "-l [num]", "", "Get number of previous lines, default is 20"},
    .{"", "-w, -f", "", "", "Listen to new logs coming in"},
    .{""},
};

test "commands/logs.zig" {
    std.debug.print("\n--- commands/logs.zig ---\n", .{});
}

test "Parse logs command args" {
    std.debug.print("Parse logs command args\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const linesf = try std.fmt.allocPrint(util.gpa, "-l", .{});
    defer util.gpa.free(linesf);
    try args.append(linesf);
    const linesv = try std.fmt.allocPrint(util.gpa, "200", .{});
    defer util.gpa.free(linesv);
    try args.append(linesv);

    const watchf = try std.fmt.allocPrint(util.gpa, "-w", .{});
    defer util.gpa.free(watchf);
    try args.append(watchf);

    const helpf = try std.fmt.allocPrint(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

    log.debug = false;
    const debugf = try std.fmt.allocPrint(util.gpa, "-d", .{});
    defer util.gpa.free(debugf);
    try args.append(debugf);

    const test_tidv = try std.fmt.allocPrint(util.gpa, "1", .{});
    defer util.gpa.free(test_tidv);
    try args.append(test_tidv);

    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var all_task_ids = [_]TaskId{1, 2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };

    var flags = try parse_cmd_args(args.items, &tasks);
    defer flags.args.deinit();

    try expect(flags.lines == 200);
    try expect(flags.watch);
    try expect(flags.help);
    try expect(log.debug);
    try expect(flags.args.ids.?[0] == 1);
}

test "Too many ids passed" {
    std.debug.print("Too many ids passed\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const test_tidv = try std.fmt.allocPrint(util.gpa, "1", .{});
    defer util.gpa.free(test_tidv);
    try args.append(test_tidv);

    const test_tid2v = try std.fmt.allocPrint(util.gpa, "2", .{});
    defer util.gpa.free(test_tid2v);
    try args.append(test_tid2v);

    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var all_task_ids = [_]TaskId{1, 2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };
    const flags = parse_cmd_args(args.items, &tasks);


    try expect(flags == error.OnlyOneTaskId);
}

test "No id passed" {
    std.debug.print("No id passed\n", .{});
    const args = try util.gpa.alloc([]u8, 0);
    defer util.gpa.free(args);

    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var all_task_ids = [_]TaskId{1, 2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };
    const flags = parse_cmd_args(args, &tasks);

    try expect(flags == error.MissingTaskId);
}
