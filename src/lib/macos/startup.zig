const std = @import("std");

const log = @import("../log.zig");
const util = @import("../util.zig");
const Lengths = util.Lengths;
const TaskId = @import("../task/index.zig").TaskId;
const TaskManager = @import("../task/manager.zig").TaskManager;
const MainFiles = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

const ChildProcess = std.process.Child;

const plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple Computer//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n<key>Label</key>\n<string>com.multask.startup</string>\n<key>ProgramArguments</key>\n<array>\n<string>{s}</string>\n<string>startup</string>\n</array>\n<key>RunAtLoad</key>\n<true/>\n</dict>\n</plist>";

fn get_multask_launch_file_content() Errors![]u8 {
    const exe_path = try util.get_mlt_exe_path();
    defer util.gpa.free(exe_path);
    const content = std.fmt.allocPrint(util.gpa, plist, .{exe_path})
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    return content;
}

fn get_launch_path() Errors![]u8 {
    const home = std.process.getEnvVarOwned(util.gpa, "HOME")
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);
    defer util.gpa.free(home);

    const path = std.fs.path.join(util.gpa, &.{ home, "Library/LaunchAgents/com.multask.startup.plist" })
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);
    return path;
}

fn launch_file_exists() Errors!bool {
    const path = try get_launch_path();
    defer util.gpa.free(path);

    const file = std.fs.openFileAbsolute(path, .{.mode = .read_only})
        catch |err| return switch(err) {
            error.FileNotFound => false,
            else => true
        };
    defer file.close();
    return true;
}

fn create_launch_file() Errors!void {
    const content = try get_multask_launch_file_content();
    defer util.gpa.free(content);

    const path = try get_launch_path();
    defer util.gpa.free(path);

    const file = std.fs.createFileAbsolute(path, .{})
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    defer file.close();

    file.writeAll(content)
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
}

fn load_launchctl() Errors!void {
    const path = try get_launch_path();
    var child = ChildProcess.init(&[_][]const u8{"launchctl", "load", path}, util.gpa);
    child.stderr_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stdin_behavior = .Close;
    child.spawn()
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    _ = child.wait()
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
}

/// Checks if the mlt startup command is being ran at startup
pub fn set_run_on_boot() Errors!void {
    const exists = try launch_file_exists();
    if (exists) {
        return;
    }

    try create_launch_file();
    try load_launchctl();
}
