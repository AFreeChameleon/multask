const std = @import("std");
const expect = std.testing.expect;

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const Task = t.Task;

const TaskManager  = @import("../lib/task/manager.zig").TaskManager;

const f = @import("../lib/file.zig");
const MainFiles = f.MainFiles;
const CheckFiles = f.CheckFiles;

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const parse = @import("../lib/args/parse.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    help: bool,
};

pub fn run(argv: [][]u8) Errors!void {
    const flags = try parse_cmd_args(argv);

    if (flags.help) {
        try log.print_help(help_rows);
        return;
    }

    // Checking if files exist
    try CheckFiles.check_all();

    var tasks = try TaskManager.get_tasks();
    defer tasks.deinit();
    try log.printsucc("Namespaces are healthy", .{});
    for (tasks.task_ids) |task_id| {
        try log.printinfo("Getting task with id: {d}", .{task_id});
        var task = Task.init(task_id);
        defer task.deinit();
        TaskManager.get_task_from_id(&task)
            catch |err| {
                try log.print_custom_err(" Cannot get task with id: {d}", .{task_id});
                try log.printerr(err);
                continue;
            };
        try log.printsucc("Task {d} is healthy", .{task_id});
    }
}

pub fn parse_cmd_args(argv: [][]u8) Errors!Flags {
    var flags = Flags {
        .help = false,
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

    return flags;
}

const help_rows = .{
    .{"Checks each task to see if they are healthy and not corrupted."},
    .{"Run this when this tool breaks."},
    .{"Usage: mlt health"},
    .{""},
    .{"For more, run `mlt help`"},
};

test "commands/health.zig" {
    std.debug.print("\n--- commands/health.zig ---\n", .{});
}

test "Parse health command args" {
    std.debug.print("Parse health command args\n", .{});
    var args = std.ArrayList([]u8).init(util.gpa);
    defer args.deinit();

    const helpf = try std.fmt.allocPrint(util.gpa, "-h", .{});
    defer util.gpa.free(helpf);
    try args.append(helpf);

    const debugf = try std.fmt.allocPrint(util.gpa, "-d", .{});
    defer util.gpa.free(debugf);
    try args.append(debugf);

    const flags = try parse_cmd_args(args.items);

    try expect(flags.help);
    try expect(log.debug);
}
