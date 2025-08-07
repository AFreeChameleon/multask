const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

const Task = @import("./index.zig").Task;
const util = @import("../util.zig");
const Pid = util.Pid;
const e = @import("../error.zig");
const Errors = e.Errors;

const f = @import("./file.zig");
const ProcessSection = f.ProcessSection;
const ReadProcess = f.ReadProcess;

const r = @import("./resources.zig");
const Resources = r.Resources;
const JSON_Resources = r.JSON_Resources;

pub const ExistingLimits = struct {
    mem: util.MemLimit,
    cpu: util.CpuLimit
};

pub const CpuStatus = enum {
    Sleep,
    Active
};

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

pub fn save_files(proc: *Process) Errors!void {
    try save_processes(proc);
    try save_resources(proc);
}

fn save_processes(proc: *Process) Errors!void {
    try proc.task.files.clear_file(ReadProcess);
    var children_procs = util.gpa.alloc(
        ProcessSection,
        if (proc.children == null) 0 else proc.children.?.len
    ) catch |err| return e.verbose_error(err, error.FailedToGetProcesses);

    if (proc.children != null) {
        for (proc.children.?, 0..) |child, i| {
            children_procs[i] = ProcessSection {
                .pid = child.pid,
                .starttime = child.start_time
            };
        }
    }

    if (proc.task.daemon == null) return error.TaskNotRunning;

    var read_proc = ReadProcess {
        .task = .{
            .pid = proc.task.daemon.?.pid,
            .starttime = proc.task.daemon.?.start_time
        },
        .pid = proc.pid,
        .starttime = proc.start_time,
        .children = children_procs
    }; 
    defer read_proc.deinit();

    try proc.task.files.write_file(ReadProcess, read_proc);
}

fn save_resources(proc: *Process) Errors!void {
    try proc.task.files.clear_file(JSON_Resources);
    var resources = Resources.init();
    defer resources.deinit();
    const self_usage = try Cpu.get_cpu_usage(proc);
    resources.cpu.put(proc.pid, self_usage)
        catch |err| return e.verbose_error(err, error.FailedToGetProcesses);

    if (proc.children != null) {
        for (proc.children.?) |*child| {
            const usage = try Cpu.get_cpu_usage(child);
            resources.cpu.put(child.pid, usage)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }
    }

    const json_resources = try resources.to_json();
    defer json_resources.deinit();
    try proc.task.files.write_file(JSON_Resources, json_resources);
}

/// Reads child processes in the `processes.json` file and checks
/// if any of those still exist. This is for commands like `code .`
/// which spawn processes and kills the main one.
///
/// Returns array of child processes that still exist
pub fn get_running_saved_procs(proc: *Process) Errors![]Process {
    var children = std.ArrayList(Process).init(util.gpa);
    defer children.deinit();
    var saved_procs = try proc.task.files.read_file(ReadProcess);
    if (saved_procs == null) {
        return children.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
    }
    defer saved_procs.?.deinit();
    for (saved_procs.?.children) |child_readproc| {
        var cproc = Process.init(proc.task, child_readproc.pid, null)
            catch continue;
        if (cproc.proc_exists()) {
            children.append(cproc)
                catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
        }
    }
    return children.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.FailedToGetProcessChildren);
}

pub fn parse_readprocess(task: *Task, readproc: *ReadProcess) Errors!Process {
    var mainproc = try Process.init(task, readproc.pid, readproc.starttime);
    var childprocs = std.ArrayList(Process).init(util.gpa);
    defer childprocs.deinit();
    for (readproc.children) |rchild| {
        var child = try Process.init(task, rchild.pid, rchild.starttime);
        if (child.proc_exists()) {
            childprocs.append(child)
                catch |err| return e.verbose_error(err, error.FailedToGetProcesses);
        }
    }
    if (readproc.children.len > 0) {
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
