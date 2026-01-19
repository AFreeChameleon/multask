const std = @import("std");
const expect = std.testing.expect;
const builtin = @import("builtin");
const log = @import("./log.zig");
const task = @import("./task/index.zig");
const TaskId = task.TaskId;

const m = @import("./task/manager.zig");
const Tasks = m.Tasks;
const TaskManager = m.TaskManager;

const util = @import("./util.zig");
const Pid = util.Pid;

const e = @import("./error.zig");
const Errors = e.Errors;

const Startup = @import("./startup/index.zig").Startup;

pub const MAIN_DIR: []const u8 = if (builtin.is_test) ".multi-tasker-test" else ".multi-tasker";
const TEST_HOME_DIR = "/test/home";

pub const PathBuilder = struct {
    pub const SEPARATOR = if (builtin.os.tag == .windows) '\\' else '/';

    pub fn add_main_dir(bw_writer: anytype) Errors!void {
        bw_writer.writeByte(SEPARATOR)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        bw_writer.print("{s}", .{MAIN_DIR})
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }

    pub fn add_home_dir(bw_writer: anytype) Errors!void {
        if (builtin.is_test) {
            bw_writer.print(TEST_HOME_DIR, .{})
                catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
            return;
        }
        const home_var: []const u8 = std.process.getEnvVarOwned(util.gpa, "HOME")
            catch std.process.getEnvVarOwned(util.gpa, "USERPROFILE")
                catch return error.MissingHomeDirectory;
        defer util.gpa.free(home_var);

        _ = bw_writer.write(home_var)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }

    pub fn add_tasks_dir(bw_writer: anytype) Errors!void {
        bw_writer.writeByte(SEPARATOR)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        bw_writer.print("tasks", .{})
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }

    pub fn add_task_dir(bw_writer: anytype, task_id: TaskId) Errors!void {
        bw_writer.writeByte(SEPARATOR)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        bw_writer.print("{d}", .{task_id})
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }

    pub fn add_task_file(bw_writer: anytype, filename: []const u8) Errors!void {
        bw_writer.writeByte(SEPARATOR)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        bw_writer.print("{s}", .{filename})
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }

    pub fn add_terminator(bw_writer: anytype) Errors!void {
        bw_writer.writeByte(0)
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
    }
};


pub const MainFiles = struct {
    /// CLOSE THIS
    pub fn get_or_create_main_dir() Errors!std.fs.Dir {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        var bw = std.io.bufferedWriter(fbs.writer());
        const bw_writer = &bw.writer();

        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        const dir_str = fbs.getWritten();

        const dir = std.fs.openDirAbsolute(dir_str, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.fs.makeDirAbsolute(dir_str)
                    catch |inner_err| return e.verbose_error(inner_err, error.MainDirFailedCreate);
                return std.fs.openDirAbsolute(dir_str, .{})
                    catch |inner_err| return e.verbose_error(inner_err, error.MainDirFailedCreate);
            },
            else => return error.MainDirFailedCreate
        };

        return dir;
    }

    // CLOSE THIS
    pub fn get_or_create_tasks_file_lock() Errors!std.fs.File {
        var tasks_dir = try get_or_create_tasks_dir();
        defer tasks_dir.close();
        const file = tasks_dir.openFile("tasks.json", .{ .mode = .read_write })
            catch try create_tasks_file();
        file.lock(.exclusive)
            catch |err| return e.verbose_error(err, error.MainFileFailedRead);
        return file;
    }

    pub fn get_debug_log_file() Errors!std.fs.File {
        var main_dir = try get_or_create_main_dir();
        defer main_dir.close();
        return main_dir.createFile("debug.log", .{.truncate = false})
            catch return error.DebugLogFileFailedOpen;
    }

    /// CLOSE THIS
    pub fn get_or_create_tasks_dir() Errors!std.fs.Dir {
        var main_dir = try get_or_create_main_dir();
        defer main_dir.close();
        const dir = main_dir.openDir("tasks", .{})
            catch return try create_tasks_dir();
        return dir;
    }

    /// CLOSE THIS
    pub fn create_tasks_dir() Errors!std.fs.Dir {
        try log.printinfo("Creating tasks directory...", .{});
        var main_dir = try get_or_create_main_dir();
        defer main_dir.close();
        const tasks_dir = main_dir.makeOpenPath("tasks", .{})
            catch return error.TasksDirFailedCreate;
        return tasks_dir;
    }

    /// CLOSE THIS
    pub fn create_tasks_file() Errors!std.fs.File {
        var tasks_dir = try get_or_create_tasks_dir();
        defer tasks_dir.close();
        try log.printinfo("Creating tasks file...", .{});

        const file = tasks_dir.createFile("tasks.json", .{.read = true})
            catch return error.TasksIdsFileFailedCreate;
        const placeholder = try Tasks.json_empty();
        defer util.gpa.free(placeholder.task_ids);
        std.json.stringify(placeholder, .{}, file .writer())
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedWrite);
        file.close();

        const tasks_file = tasks_dir.openFile("tasks.json", .{.mode = .read_write})
            catch return error.TasksIdsFileFailedCreate;

        return tasks_file;
    }

    pub fn create_task_files(task_id: task.TaskId) Errors!void {
        try log.printinfo("Creating task files...", .{});
        var tasks_dir = try get_or_create_tasks_dir();
        defer tasks_dir.close();

        var buf: [32]u8 = undefined;
        const task_path = std.fmt.bufPrint(&buf, "{d}", .{task_id})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);

        var task_dir = tasks_dir.makeOpenPath(task_path, .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer task_dir.close();

        const stdout = task_dir.createFile("stdout", .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer stdout.close();

        const stderr = task_dir.createFile("stderr", .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer stderr.close();

        const processes = task_dir.createFile("processes.json", .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer processes.close();

        const stats = task_dir.createFile("stats.json", .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer stats.close();

        const resources = task_dir.createFile("resources.json", .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer resources.close();

        const env = task_dir.createFile("env.json", .{})
            catch |err| return e.verbose_error(err, error.TaskFileFailedCreate);
        defer env.close();
    }
    
    /// FREE THIS
    pub fn build_main_dir_str() Errors![]const u8 {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        var bw = std.io.bufferedWriter(fbs.writer());
        const bw_writer = &bw.writer();

        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);
        const dir_str = fbs.getWritten();

        return dir_str;
    }

    /// FREE THIS
    pub fn build_tasks_dir_str() Errors![]const u8 {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        var bw = std.io.bufferedWriter(fbs.writer());
        const bw_writer = &bw.writer();

        try PathBuilder.add_home_dir(bw_writer);
        try PathBuilder.add_main_dir(bw_writer);
        try PathBuilder.add_tasks_dir(bw_writer);
        bw.flush()
            catch |err| return e.verbose_error(err, error.TasksIdsFileFailedRead);

        const dir_str = fbs.getWritten();

        return dir_str;
    }
};

pub const CheckFiles = struct {
    pub fn check_all() Errors!void {
        try check_main_dir();
        try check_tasks_dir();
        try check_main_file();
        try check_tasks();
    }

    fn check_main_dir() Errors!void {
        const main_dir_str = try MainFiles.build_main_dir_str();
        var main_dir = std.fs.openDirAbsolute(main_dir_str, .{})
            catch |err| return e.verbose_error(err, error.MainDirNotFound);
        defer main_dir.close();
        if (!util.dir_exists(main_dir)) {
            return error.MainDirNotFound;
        }
    }

    fn check_tasks_dir() Errors!void {
        const tasks_dir_str = try MainFiles.build_main_dir_str();
        var tasks_dir = std.fs.openDirAbsolute(tasks_dir_str, .{})
            catch |err| return e.verbose_error(err, error.TasksDirNotFound);
        defer tasks_dir.close();
        if (!util.dir_exists(tasks_dir)) {
            return error.TasksDirNotFound;
        }
    }

    fn check_main_file() Errors!void {
        const tasks_dir_str = try MainFiles.build_tasks_dir_str();
        const file_str = std.fmt.allocPrint(util.gpa, "{s}/tasks.json", .{tasks_dir_str})
            catch |err| return e.verbose_error(err, error.TasksIdsFileNotExists);
        defer util.gpa.free(file_str);
        const file = std.fs.openFileAbsolute(file_str, .{.mode = .read_only})
            catch |err| return e.verbose_error(err, error.TasksIdsFileNotExists);
        defer file.close();
        if (!util.file_exists(file)) {
            return error.TasksIdsFileNotExists;
        }
    }

    fn check_tasks() Errors!void {
        const tasks_dir_str = try MainFiles.build_tasks_dir_str();
        var tasks_dir = std.fs.openDirAbsolute(tasks_dir_str, .{.iterate = true})
            catch |err| return e.verbose_error(err, error.TasksDirNotFound);
        defer tasks_dir.close();

        var dir_itr = tasks_dir.iterate();

        while (
            dir_itr.next()
                catch |err| return e.verbose_error(err, error.TasksDirNotFound)
        ) |entry| {
            if (
                std.mem.eql(u8, entry.name, "tasks.json")
            ) {
                continue;
            }
            try log.printinfo("Testing item: {s}", .{entry.name});
            if (entry.kind != .directory) {
                try log.printwarn("Unknown file {s} in tasks dir", .{entry.name});
                continue;
            }
            const path = std.fmt.allocPrint(util.gpa, "{s}/{s}", .{tasks_dir_str, entry.name})
                catch |err| return e.verbose_error(err, error.TasksDirNotFound);
            defer util.gpa.free(path);
            var dir = tasks_dir.openDir(entry.name, .{.iterate = true})
                catch blk: {
                    try log.printwarn("Unknown file {s} in tasks dir", .{entry.name});
                    break :blk null;
                };
            if (dir != null) {
                defer dir.?.close();
                try check_task_subdirs(dir.?);
            }
        }
    }

    fn check_task_subdirs(subdir: std.fs.Dir) Errors!void {
        var dir_itr = subdir.iterate();
        var files = std.StringHashMap(bool).init(util.gpa);
        defer files.deinit();
        const subdir_filenames: [6][]const u8 = .{
            "processes.json", "stats.json", "stdout", "stderr", "resources.json", "env.json"
        };

        while (
            dir_itr.next()
                catch |err| return e.verbose_error(err, error.TasksDirNotFound)
        ) |entry| {
            var found = false;
            try log.printinfo("Found inner item: {s}", .{entry.name});
            if (entry.kind == .directory) {
                try log.printwarn("Unknown file {s} in task dir", .{entry.name});
                continue;
            }
            for (subdir_filenames) |name| {
                if (std.mem.eql(u8, entry.name, name)) {
                    found = true;
                    const file = subdir.openFile(entry.name, .{.mode = .read_only})
                        catch blk: {
                            try print_subdir_err_file(entry.name);
                            break :blk null;
                        };
                    if (file != null) {
                        defer file.?.close();
                        files.put(name, true)
                            catch |err| return e.verbose_error(err, error.TasksDirNotFound);
                    }
                }
            }
            if (!found) {
                try log.printwarn("Unknown file {s} in task dir", .{entry.name});
            }
        }

        for (subdir_filenames) |filename| {
            const file_exists = files.get(filename);
            if (file_exists == null or file_exists.? == false) {
                try log.print_custom_err(" Missing essential file `{s}` in task dir", .{filename});
            }
        }
    }

    fn print_subdir_err_file(name: []const u8) Errors!void {
        if (std.mem.eql(u8, name, "processes")) {
            try log.printerr(error.ProcessNotExists);
        } else if (std.mem.eql(u8, name, "stats")) {
            try log.printerr(error.FailedToGetTaskStats);
        } else if (std.mem.eql(u8, name, "stdout")) {
            try log.printerr(error.TaskLogsFailedToRead);
        } else if (std.mem.eql(u8, name, "stderr")) {
            try log.printerr(error.TaskLogsFailedToRead);
        } else if (std.mem.eql(u8, name, "resources")) {
            try log.printerr(error.FailedToGetCpuUsage);
        } else {
            try log.printerr(error.UnkownItemInTaskDir);
        }
    }
};

test "lib/file.zig" {
    std.debug.print("\n--- lib/file.zig ---\n", .{});
}

test "PathBuilder build to task file" {
    std.debug.print("PathBuilder build to task file\n", .{});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var bw = std.io.bufferedWriter(fbs.writer());
    const bw_writer = &bw.writer();

    try PathBuilder.add_main_dir(bw_writer);
    try PathBuilder.add_tasks_dir(bw_writer);
    try PathBuilder.add_task_dir(bw_writer, 1);
    try PathBuilder.add_task_file(bw_writer, "stdout");
    const end = bw.end;
    try bw.flush();

    var buf: [128]u8 = undefined;
    const res = try std.fmt.bufPrint(
        &buf,
        "{c}.multi-tasker-test{c}tasks{c}1{c}stdout",
        .{PathBuilder.SEPARATOR, PathBuilder.SEPARATOR, PathBuilder.SEPARATOR, PathBuilder.SEPARATOR}
    );

    try expect(std.mem.eql(u8, buffer[0..end], res));
}
