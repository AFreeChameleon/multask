const std = @import("std");

const t = @import("../lib/task/index.zig");
const TaskId = t.TaskId;
const TaskManager = t.TaskManager;

const f = @import("../lib/file.zig");
const MainFiles = f.MainFiles;
const CheckFiles = f.CheckFiles;

const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

const log = @import("../lib/log.zig");
const getopt = @import("../lib/args/getopt.zig");

const e = @import("../lib/error.zig");
const Errors = e.Errors;

pub const Flags = struct {
    help: bool,
};

pub fn run() Errors!void {
    const flags = try parse_args();
    if (flags.help) return;

    // Checking if files exist
    try CheckFiles.check_all();

    _ = try TaskManager.get_namespaces();
    try log.printsucc("Namespaces are healthy", .{});
    const tasks_ids = try TaskManager.get_taskids();
    for (tasks_ids) |task_id| {
        try log.printinfo("Getting task with id: {d}", .{task_id});
        _ = TaskManager.get_task_from_id(task_id)
            catch |err| {
                try log.print_custom_err(" Cannot get task with id: {d}", .{task_id});
                try log.printerr(err);
                continue;
            };
        try log.printsucc("Task {d} is healthy", .{task_id});
    }
}

pub fn parse_args() Errors!Flags {
    var opts = getopt.getopt("dh");
    var flags = Flags {
        .help = false,
    };

    var next_val = try opts.next();
    while (!opts.optbreak) {
        if (next_val == null) {
            next_val = try opts.next();
            continue;
        }
        const opt = next_val.?;
        switch (opt.opt) {
            'h' => {
                flags.help = true;
                try print_help();
                return flags;
            },
            'd' => {
                log.enable_debug();
                try log.printdebug("DEBUG MODE", .{});
            },
            else => unreachable,
        }
        next_val = try opts.next();
    }

    return flags;
}

fn print_help() Errors!void {
    try log.print_help(rows);
}

const rows = .{
    .{"Checks each task to see if they are healthy and not corrupted."},
    .{"Run this when this tool breaks."},
    .{"Usage: mlt health"},
    .{""},
    .{"For more, run `mlt help`"},
};
