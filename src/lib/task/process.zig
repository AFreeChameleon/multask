const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

const t = @import("./index.zig");
const Task = t.Task;
const TaskId = t.TaskId;
const util = @import("../util.zig");
const Pid = util.Pid;
const e = @import("../error.zig");
const Errors = e.Errors;

const f = @import("./file.zig");
const ReadProcess = f.ReadProcess;
const TaskReadProcess = f.TaskReadProcess;
const Files = f.Files;

const r = @import("./resources.zig");
const Resources = r.Resources;
const JSON_Resources = r.JSON_Resources;

const taskenv = @import("./env.zig");
const JSON_Env = taskenv.JSON_Env;

pub const Process = switch (builtin.target.os.tag) {
    .linux => @import("../linux/process.zig").LinuxProcess,
    .macos => @import("../macos/process.zig").MacosProcess,
    .windows => @import("../windows/process.zig").WindowsProcess,
    else => error.InvalidOS
};

pub const Cpu = switch (builtin.target.os.tag) {
    .linux => @import("../linux/cpu.zig").LinuxCpu,
    .macos => @import("../macos/cpu.zig").MacosCpu,
    .windows => @import("../windows/cpu.zig").WindowsCpu,
    else => error.InvalidOS
};

pub const ExistingLimits = struct {
    mem: util.MemLimit,
    cpu: util.CpuLimit
};

pub const CpuStatus = enum {
    Sleep,
    Active
};

pub const Monitoring = enum {
    Deep,
    Shallow
};

pub fn save_files(proc: *Process) Errors!void {
    save_processes(proc)
        catch |err| switch (err) {
            error.TaskFileNotFound => {},
            else => return err
        };
    save_resources(proc)
        catch |err| switch (err) {
            error.TaskFileNotFound => {},
            else => return err
        };
}

fn save_processes(proc: *Process) Errors!void {
    try log.printdebug("Saving processes", .{});
    const file = try proc.task.files.?.get_file_locked(ReadProcess);
    defer {
        file.unlock();
        file.close();
    }
    var children_procs = util.gpa.alloc(
        ReadProcess,
        if (proc.children == null) 0 else proc.children.?.len
    ) catch |err| return e.verbose_error(err, error.FailedToGetProcesses);

    const task_proc = TaskReadProcess.init(&proc.task.daemon.?);
    if (proc.children != null) {
        for (proc.children.?, 0..) |child, i| {
            children_procs[i] = ReadProcess.init(&child, task_proc, null);
        }
    }

    if (proc.task.daemon == null) return error.TaskNotRunning;

    var read_proc = ReadProcess.init(proc, task_proc, children_procs);
    defer read_proc.deinit();

    try Files.write_file(&file, ReadProcess, read_proc);
}

fn save_resources(proc: *Process) Errors!void {
    if (proc.task.resources.?.meta == null) {
        return error.FailedToGetProcesses;
    }
    try log.printdebug("Saving resources", .{});

    const file = try proc.task.files.?.get_file_locked(JSON_Resources);
    defer {
        file.unlock();
        file.close();
    }

    var resources = Resources.init();
    defer resources.deinit();
    if (proc.proc_exists()) {
        const self_usage = try proc.task.resources.?.meta.?.get_cpu_usage(proc);
        resources.cpu.put(proc.pid, self_usage)
            catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
    }

    if (proc.children != null) {
        for (proc.children.?) |*child| {
            if (child.proc_exists()) {
                const usage = try proc.task.resources.?.meta.?.get_cpu_usage(child);
                resources.cpu.put(child.pid, usage)
                    catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
            }
        }
    }

    const json_resources = try resources.to_json();
    defer json_resources.deinit();
    try Files.write_file(&file, JSON_Resources, json_resources);
}

/// Reads child processes in the `processes.json` file and checks
/// if any of those still exist. This is for commands like `code .`
/// which spawn processes and kills the main one.
///
/// Returns array of child processes that still exist
pub fn get_running_saved_procs(proc: *Process) Errors![]Process {
    try log.printdebug("Get running saved processes", .{});
    var children = std.ArrayList(Process).init(util.gpa);
    defer children.deinit();
    // This may sometimes fail due to a read happening while a daemon is trying to save to it
    var saved_procs = proc.task.files.?.read_file(ReadProcess)
        catch |err| switch (err) {
            error.TaskFileFailedRead => return &[0]Process{},
            else => return err
        };
    if (saved_procs == null) {
        return children.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
    }
    defer saved_procs.?.deinit();
    if (saved_procs.?.children == null) {
        return error.FailedToGetProcessChildren;
    }
    for (saved_procs.?.children.?) |child_readproc| {
        const args = Process.get_init_args_from_readproc(ReadProcess, child_readproc);
        var cproc = Process.init(proc.task, child_readproc.pid, args) catch continue;
        if (cproc.proc_exists()) {
            children.append(cproc)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        }
    }
    return children.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
}

pub fn parse_readprocess(task: *Task, readproc: *ReadProcess) Errors!Process {
    const args = Process.get_init_args_from_readproc(ReadProcess, readproc.*);
    var mainproc = try Process.init(task, readproc.pid, args);
    var childprocs = std.ArrayList(Process).init(util.gpa);
    defer childprocs.deinit();
    if (readproc.children == null) {
        return error.FailedToGetProcessChildren;
    }
    for (readproc.children.?) |rchild| {
        const child_args = Process.get_init_args_from_readproc(ReadProcess, rchild);
        var child = try Process.init(task, rchild.pid, child_args);
        if (child.proc_exists()) {
            childprocs.append(child)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }
    }
    if (readproc.children.?.len > 0) {
        mainproc.children = childprocs.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
    }
    return mainproc;
}

pub fn check_memory_limit_within_limit(self: *Process) Errors!void {
    if (self.memory_limit != 0) {
        const mem = try self.get_memory();
        if (mem > self.memory_limit) {
            try self.kill();
        }
    }
    if (self.children != null) {
        for (self.children.?) |*child| {
            if (self.memory_limit != 0) {
                const mem = try child.get_memory();
                if (mem > self.memory_limit) {
                    try child.kill();
                }
            }
        }
    }
}

pub fn kill_all(proc: *Process) Errors!void {
    try log.printdebug("Killing all processes.", .{});
    if (builtin.target.os.tag == .windows) {
        try proc.kill_all();
    } else {
        if (proc.proc_exists()) {
            var children = std.ArrayList(Process).init(util.gpa);
            defer children.deinit();
            try proc.get_children(&children, proc.pid);
            for (children.items) |*child| {
                try child.kill();
            }
            try proc.kill();
        } else {
            const saved_procs = try get_running_saved_procs(proc);
            defer util.gpa.free(saved_procs);
            if (saved_procs.len != 0) {
                for (saved_procs) |*sproc| {
                    sproc.kill() catch continue;
                }
            }
        }
    }
}

pub fn any_procs_exist(proc: *Process) Errors!bool {
    if (proc.proc_exists()) {
        return true;
    }
    if (proc.children != null) {
        for (proc.children.?) |*child| {
            if (child.proc_exists()) return true;
        }
    }
    const saved_procs = try get_running_saved_procs(proc);
    defer util.gpa.free(saved_procs);
    if (saved_procs.len != 0) {
        for (saved_procs) |*sproc| {
            if (sproc.proc_exists()) return true;
        }
    }
    return false;
}

pub fn filter_dupe_and_self_procs(self_proc: *Process, procs: []Process) Errors![]Process {
    var unique_procs = std.ArrayList(Process).init(util.gpa);
    defer unique_procs.deinit();

    for (procs) |proc| {
        var do_not_add = false;
        for (unique_procs.items) |u_proc| {
            if (proc.pid == u_proc.pid) {
                do_not_add = true;
                break;
            }
        }
        if (
            proc.pid == self_proc.pid or
            (self_proc.task.daemon != null and proc.pid == self_proc.task.daemon.?.pid)
        ) {
            do_not_add = true;
        }
        if (do_not_add) continue;

        unique_procs.append(proc)
            catch |err| return e.verbose_error(err, error.FailedToFilterDupeProcesses);
    }
    return unique_procs.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedToFilterDupeProcesses);
}

pub fn get_envs(task: *Task, update_envs: bool) Errors!std.process.EnvMap {
    try log.printdebug("Getting envs. Updating: {any}", .{update_envs});
    if (update_envs) {
        return try save_current_envs(task);
    }
    const content = task.files.?.read_file(JSON_Env)
        catch |err| return switch (err) {
            error.TaskFileNotFound => try save_current_envs(task),
            else => err
        };
    if (content == null) {
        try log.printdebug("Env file missing/invalid, saving current envs.", .{});
        return try save_current_envs(task);
    }
    defer content.?.deinit();
    const map = try content.?.to_map();
    return map;
}

pub fn save_current_envs(task: *Task) Errors!std.process.EnvMap {
    const env = std.process.getEnvMap(util.gpa)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
    const json = try taskenv.serialise(env);
    defer json.deinit();

    const file = try task.files.?.get_file_locked(JSON_Env);
    defer {
        file.unlock();
        file.close();
    }
    try Files.write_file(&file, JSON_Env, json);
    return env;
}
