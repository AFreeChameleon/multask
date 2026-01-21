const std = @import("std");
const builtin = @import("builtin");

const log = @import("../log.zig");
const util = @import("../util.zig");
const TaskId = @import("../task/index.zig").TaskId;
const TaskManager = @import("../task/manager.zig").TaskManager;
const MainFiles = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

/// Checks if the mlt startup command is being ran at startup
pub fn set_run_on_boot() Errors!void {
    if (builtin.os.tag == .linux) {
        try @import("../linux/startup.zig").set_run_on_boot();
    }
    if (builtin.os.tag == .macos) {
        try @import("../macos/startup.zig").set_run_on_boot();
    }
    if (builtin.os.tag == .windows) {
        try @import("../windows/startup.zig").set_run_on_boot();
    }
}
