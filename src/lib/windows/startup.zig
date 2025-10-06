const std = @import("std");
const windows = std.os.windows;

const c = @import("../c.zig").libc;

const log = @import("../log.zig");
const util = @import("../util.zig");
const Lengths = util.Lengths;
const TaskId = @import("../task/index.zig").TaskId;
const TaskManager = @import("../task/manager.zig").TaskManager;
const MainFiles = @import("../file.zig").MainFiles;

const e = @import("../error.zig");
const Errors = e.Errors;

const ChildProcess = std.process.Child;

const MULTASK_REG_KEY = "multask";

/// Checks if the mlt startup command is being ran at startup
fn check_registered_for_startup() Errors!bool {
    var hkey: windows.HKEY align(8) = undefined;
    var res = windows.advapi32.RegOpenKeyExW(
        windows.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run"),
        0,
        windows.KEY_QUERY_VALUE,
        &hkey,
    );
    if (res != 0) {
        return false;
    }
    defer _ = windows.advapi32.RegCloseKey(hkey);

    var reg_type: u32 = undefined;
    var data_len: u32 = 0;
    res = windows.advapi32.RegQueryValueExW(
        hkey,
        std.unicode.utf8ToUtf16LeStringLiteral(MULTASK_REG_KEY),
        null,
        &reg_type,
        null,
        &data_len,
    );
    return res == 0;
}

fn register_startup(startup: [:0]u16) Errors!void {
    var hkey: c.HKEY align(8) = null;
    const HKEY_CURRENT_USER align(8) = @as(c.HKEY, 0x80000001);
    const res = c.RegOpenKeyExW(
        HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run"),
        0,
        c.KEY_SET_VALUE,
        &hkey,
    );
    if (res != 0) {
        return error.FailedToSetStartupDetails;
    }
    defer _ = c.RegCloseKey(hkey);
    _ = c.RegSetValueExW(
        hkey,
        std.unicode.utf8ToUtf16LeStringLiteral(MULTASK_REG_KEY),
        0,
        c.REG_SZ,
        @as([*]const u8, @ptrCast(startup.ptr)),
        @as(u32, @intCast((startup.len) * 2)), // bytes, not chars
    );
}

fn CalcStartupCommandLen() usize {
    return std.fs.max_path_bytes + " startup".len + 1;
}

fn get_mlt_startup_command_w() Errors![:0]u16 {
    const exe_path = try util.get_mlt_exe_path();
    const exe_dir = std.fs.path.dirname(exe_path);
    const bg_exe = "mlt_bg.exe";
    const bg_exe_path = std.fs.path.join(util.gpa, &.{
        if (exe_dir == null) "" else exe_dir.?,
        bg_exe
    }) catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    defer util.gpa.free(bg_exe_path);

    const startup = std.fmt.allocPrint(util.gpa, "\"{s}\" startup", .{bg_exe_path})
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);
    defer util.gpa.free(startup);
    
    const startup_w = std.unicode.utf8ToUtf16LeAllocZ(util.gpa, startup)
        catch |err| return e.verbose_error(err, error.FailedToSetStartupDetails);

    return startup_w;
}

/// Checks if the mlt startup command is being ran at startup
pub fn set_run_on_boot() Errors!void {
    const startupw = try get_mlt_startup_command_w();
    defer util.gpa.free(startupw);

    const exists = try check_registered_for_startup();

    if (exists) {
        return;
    }

    try register_startup(startupw);
}

