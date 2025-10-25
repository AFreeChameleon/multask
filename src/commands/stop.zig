const std = @import("std");
const expect = std.testing.expect;

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const tm = @import("../lib/task/manager.zig");
const TaskManager = tm.TaskManager;
const Tasks = tm.Tasks;

const taskproc = @import("../lib/task/process.zig");

const file = @import("../lib/file.zig");

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");

const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    help: bool,
    args: util.TaskArgs
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

    if (flags.args.ids == null) {
        try log.print_custom_err(" Missing task id.", .{});
        return error.ParsingCommandArgsFailed;
    }

    for (flags.args.ids.?) |id| {
        var new_task = Task.init(id);
        defer new_task.deinit();
        try TaskManager.get_task_from_id(
            &new_task
        );
        const task_running = try TaskManager.kill_task(&new_task);
        if (!task_running) {
            try log.printinfo("Task {d} is not running.", .{id});
            continue;
        } else {
            try log.printsucc("Task stopped with id {d}.", .{new_task.id});
        }
    }
}

pub fn parse_cmd_args(argv: [][]u8, tasks: *Tasks) Errors!Flags {
    var flags = Flags {
        .help = false,
        .args = undefined
    };
    var pflags = util.gpa.alloc(parse.Flag, 2)
        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
    defer util.gpa.free(pflags);
    pflags[0] = parse.Flag {
        .name = 'd',
        .type = .static
    };
    pflags[1] = parse.Flag {
        .name = 'h',
        .type = .static
    };

    const vals = try parse.parse_args(argv, pflags);
    defer util.gpa.free(vals);

    for (pflags) |flag| {
        if (!flag.exists) {
            continue;
        }
        switch (flag.name) {
            'h' => flags.help = true,
            'd' => log.enable_debug(),
            else => continue
        }
    }

    // Removing the exe name and the initial command
    const parsed_args = try util.parse_cmd_vals(vals, tasks);
    flags.args = parsed_args;
    if (vals.len == 0) {
        flags.args.deinit();
        return error.MissingTaskId;
    }
    return flags;
}

pub const help_rows = .{
    .{"mlt stop"},
    .{"Stops tasks by task id or namespace"},
    .{"Usage: mlt stop all"},
    .{""},
};

test "commands/stop.zig" {
    std.debug.print("\n--- commands/stop.zig ---\n", .{});
}

test "Parse stop command args" {
    std.debug.print("Parse stop command args\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const helpf = try std.fmt.allocPrint(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

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

    try expect(flags.help);
    try expect(log.debug);
    try expect(flags.args.ids.?[0] == 1);
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
