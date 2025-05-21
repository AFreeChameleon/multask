const std = @import("std");
const expect = std.testing.expect;

const task = @import("../lib/task/index.zig");
const Task = task.Task;
const TaskId = task.TaskId;

const TaskManager = @import("../lib/task/manager.zig").TaskManager;

const Files = @import("../lib/task/file.zig").Files;

const taskproc = @import("../lib/task/process.zig");
const Process = taskproc.Process;

const ReadProcess = @import("../lib/task/file.zig").ReadProcess;

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
    var flags = try parse_cmd_args(argv);
    defer flags.args.deinit();
    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    for (flags.args.ids.?) |id| {
        const task_idx = std.mem.indexOf(TaskId, tasks.task_ids, &[1]TaskId{id});
        if (task_idx == null) {
            try log.printinfo("Task {d} does not exist.", .{id});
            continue;
        }
        var new_task = Task.init(id);
        defer new_task.deinit();
        TaskManager.get_task_from_id(
            &new_task
        ) catch {
            try log.print_custom_err(" Task {d} is corrupted. Deleting all parts of it.", .{id});
            try Task.delete_corrupt(id);
            continue;
        };


        if (new_task.process != null and try taskproc.any_procs_exist(&new_task.process.?)) {
            try log.printinfo("Killing existing processes.", .{});
            if (new_task.daemon != null) {
                try new_task.daemon.?.kill();
            }
            try taskproc.kill_all(&new_task.process.?);
        }
        try new_task.delete();
        try log.printsucc("Task deleted with id {d}.", .{new_task.id});
    }

}

pub fn parse_cmd_args(argv: [][]u8) Errors!Flags {
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

    const parsed_args = try util.parse_cmd_vals(vals);
    flags.args = parsed_args;
    if (vals.len == 0) {
        flags.args.deinit();
        return error.MissingTaskId;
    }
    return flags;
}

const help_rows = .{
    .{"Deletes tasks and kills any process that's running under them."},
    .{"Usage: mlt delete 1 2 ns_one"},
    .{""},
    .{"For more, run `mlt help`"},
};

test "commands/delete.zig" {
    std.debug.print("\n--- commands/delete.zig ---\n", .{});
}

test "Parse delete command args" {
    std.debug.print("Parse delete command args\n", .{});
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

    var flags = try parse_cmd_args(args.items);
    defer flags.args.deinit();

    try expect(flags.help);
    try expect(log.debug);
    try expect(flags.args.ids.?[0] == 1);
}

test "No id passed" {
    std.debug.print("No id passed\n", .{});
    const args = try util.gpa.alloc([]u8, 0);
    defer util.gpa.free(args);

    const flags = parse_cmd_args(args);

    try expect(flags == error.MissingTaskId);
}
