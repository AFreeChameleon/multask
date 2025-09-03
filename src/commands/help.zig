const std = @import("std");
const log = @import("../lib/log.zig");
const e = @import("../lib/error.zig");
const util = @import("../lib/util.zig");
const Lengths = util.Lengths;

pub fn run() e.Errors!void {
    try log.print_help(rows);
}

const rows = .{
    .{"Usage: mlt [option] [flags] [values]"},
    .{"options:"},
    .{ "", "create", "Create a task and run it. [value] must be a command e.g \"ping google.com\"" },
    .{ "", "", "-m [num]", "Set maximum memory limit e.g 4GB" },
    .{ "", "", "-c [num]", "Set limit cpu usage by percentage e.g 20" },
    .{ "", "", "-n [text]", "Set namespace for the task" },
    .{ "", "", "-i", "", "Interactive mode (can use aliased commands on your environment)" },
    .{ "", "", "-p", "", "Persist mode (will restart if the program exits)" },
    .{ "", "", "-M, --monitor", "How thorough looking for child processes will be, use \"deep\" for complex applications like GUIs although it can be a little more CPU intensive, \"shallow\" is the default." },
    .{""},
    .{ "", "stop", "Stops a task. [value] must be task ids or a namespace" },
    .{""},
    .{ "", "start", "Starts a task. [value] must be task ids or a namespace" },
    .{ "", "", "-m [num]", "Set maximum memory limit e.g 4GB" },
    .{ "", "", "-c [num]", "Set limit cpu usage by percentage e.g 20" },
    .{ "", "", "-i", "", "Interactive mode (can use aliased commands on your environment)" },
    .{ "", "", "-p", "", "Persist mode (will restart if the program exits)" },
    .{ "", "", "-e", "", "Updates env variables with your current environment." },
    .{ "", "", "-M, --monitor", "How thorough looking for child processes will be, use \"deep\" for complex applications like GUIs although it can be a little more CPU intensive, \"shallow\" is the default." },
    .{""},
    .{ "", "edit", "Edits a task. [value] must be task ids or a namespace" },
    .{ "", "", "-m [num]", "Set maximum memory limit e.g 4GB" },
    .{ "", "", "-c [num]", "Set limit cpu usage by percentage e.g 20" },
    .{ "", "", "-n [text]", "Set namespace for the task" },
    .{ "", "", "-p", "", "Persist mode (will restart if the program exits)" },
    .{ "", "", "-M, --monitor", "How thorough looking for child processes will be, use \"deep\" for complex applications like GUIs although it can be a little more CPU intensive, \"shallow\" is the default." },
    .{""},
    .{ "", "restart", "Restarts a task. [value] must be task ids or a namespace" },
    .{ "", "", "-m [num]", "Set maximum memory limit e.g 4GB" },
    .{ "", "", "-c [num]", "Set limit cpu usage by percentage e.g 20" },
    .{ "", "", "-i", "", "Interactive mode (can use aliased commands on your environment)" },
    .{ "", "", "-p", "", "Persist mode (will restart if the program exits)" },
    .{ "", "", "-e", "", "Updates env variables with your current environment." },
    .{ "", "", "-M, --monitor", "How thorough looking for child processes will be, use \"deep\" for complex applications like GUIs although it can be a little more CPU intensive, \"shallow\" is the default." },
    .{""},
    .{ "", "ls", "Shows all tasks" },
    .{ "", "", "-w, -f", "Provides updating tables every 2 seconds" },
    .{ "", "", "-a", "Show all child processes" },
    .{""},
    .{ "", "logs", "Shows output from task. [value] must be a task id e.g 1" },
    .{ "", "", "-l [num]", "See number of previous lines default is 20" },
    .{ "", "", "-w, -f", "", "Listen to new logs coming in" },
    .{""},
    .{ "", "delete", "Deletes tasks. [value] must be a task id or a namespace e.g 1" },
    .{""},
    .{ "", "health", "Checks state of multask, run this when multask is not working" },
    .{""},
    .{ "", "help", "Shows available options" },
};
