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
    .{"", "create", "Create a task and run it. [value] must be a command e.g \"ping google.com\""},
    .{"", "", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "", "-n [text]", "Set namespace for the task"},
    .{"", "", "-i", "", "Interactive mode (can use aliased commands on your environment)"},
    .{"", "", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"", "stop", "Stops a task. [value] must be task ids or a namespace"},
    .{""},
    .{"", "start", "Starts a task. [value] must be task ids or a namespace"},
    .{"", "", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "", "-i", "", "Interactive mode (can use aliased commands on your environment)"},
    .{"", "", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"", "edit", "Edits a task. [value] must be task ids or a namespace"},
    .{"", "", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "", "-n [text]", "Set namespace for the task"},
    .{"", "", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"", "restart", "Restarts a task. [value] must be task ids or a namespace"},
    .{"", "", "-m [num]", "Set maximum memory limit e.g 4GB"},
    .{"", "", "-c [num]", "Set limit cpu usage by percentage e.g 20"},
    .{"", "", "-i", "", "Interactive mode (can use aliased commands on your environment)"},
    .{"", "", "-p", "", "Persist mode (will restart if the program exits)"},
    .{""},
    .{"", "ls", "Shows all taskes"},
    .{"", "", "-w", "Provides updating tables every 2 seconds"},
    .{"", "", "-a", "Show all child taskes"},
    .{""},
    .{"", "logs", "Shows output from task. [value] must be a task id e.g 1"},
    .{"", "", "-l [num]", "See number of previous lines default is 20"},
    .{"", "", "-w", "", "Listen to new logs coming in"},
    .{""},
    .{"", "delete", "Deletes tasks. [value] must be a task id or a namespace e.g 1"},
    .{""},
    .{"", "health", "Checks state of multask, run this when multask is not working"},
    .{""},
    .{"", "help", "Shows available options"},
};
