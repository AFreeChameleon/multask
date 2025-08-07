const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");
const file = @import("../file.zig");
const Task = @import("./index.zig").Task;
const util = @import("../util.zig");
const Pid = util.Pid;
const e = @import("../error.zig");
const Errors = e.Errors;

const LinuxProcess = if (builtin.target.os.tag == .linux)
    @import("../linux/process.zig").LinuxProcess
else
    bool;
const MacosProcess = if (builtin.target.os.tag == .macos)
    @import("../macos/process.zig").MacosProcess
else
    bool;
const WindowsProcess = if (builtin.target.os.tag == .windows)
    @import("../windows/process.zig").WindowsProcess
else
    bool;

pub const ExistingLimits = struct {
    mem: util.MemLimit,
    cpu: util.CpuLimit
};

pub const CpuStatus = enum {
    Sleep,
    Active
};

const ProcessEnum = enum {
    linux,
    macos,
    windows
};
pub const Process = union(ProcessEnum) {
    const Self = @This();

    linux: LinuxProcess,
    macos: MacosProcess,
    windows: WindowsProcess,

    pub fn init(
        pid: Pid,
        task: *Task,
    ) Errors!Self {
        if (comptime builtin.target.os.tag == .linux) {
            return Self {
                .linux = try LinuxProcess.init(pid, task)
            };
        }
        if (comptime builtin.target.os.tag == .macos) {
            return Self {
                .macos = try MacosProcess.init(pid, task)
            };
        }
        if (comptime builtin.target.os.tag == .windows) {
            return Self {
                .windows = try WindowsProcess.init(pid, task)
            };
        }
    }

    pub fn get_pid(self: *const Self) Pid {
        if (comptime builtin.target.os.tag == .linux) {
            return self.linux.pid;
        }
        if (comptime builtin.target.os.tag == .macos) {
            return self.macos.pid;
        }
        if (comptime builtin.target.os.tag == .windows) {
            return self.windows.pid;
        }
    }

    pub fn proc_exists(self: *Self) bool {
        if (comptime builtin.target.os.tag == .linux) {
            return self.linux.proc_exists();
        }
        if (comptime builtin.target.os.tag == .macos) {
            return self.macos.proc_exists();
        }
        if (comptime builtin.target.os.tag == .windows) {
            return self.windows.proc_exists();
        }
    }

    pub fn monitor_stats(self: *Self) Errors!void {
        if (comptime builtin.target.os.tag == .linux) {
            try self.linux.monitor_stats();
        }
        if (comptime builtin.target.os.tag == .macos) {
            try self.macos.monitor_stats();
        }
        if (comptime builtin.target.os.tag == .windows) {
            try self.windows.monitor_stats();
        }
    }

    pub fn get_child_pids(self: *Self) Errors![]util.Pid {
        if (comptime builtin.target.os.tag == .windows) {
            return try self.windows.get_all_processes();
        }
    }

    pub fn get_memory(self: *Self) Errors!u64 {
        if (comptime builtin.target.os.tag == .linux) {
            return try self.linux.get_memory();
        }
        if (comptime builtin.target.os.tag == .macos) {
            return try self.macos.get_memory();
        }
        if (comptime builtin.target.os.tag == .windows) {
            return try self.windows.get_memory();
        }
    }

    pub fn get_runtime(self: *Self) Errors!u64 {
        if (comptime builtin.target.os.tag == .linux) {
            return try self.linux.get_runtime();
        }
        if (comptime builtin.target.os.tag == .macos) {
            return try self.macos.get_runtime();
        }
        if (comptime builtin.target.os.tag == .windows) {
            return try self.windows.get_runtime();
        }
    }

    pub fn get_exe(self: *Self) Errors![]const u8 {
        if (comptime builtin.target.os.tag == .linux) {
            return try self.linux.get_exe();
        }
        if (comptime builtin.target.os.tag == .macos) {
            return try self.macos.get_exe();
        }
        if (comptime builtin.target.os.tag == .windows) {
            return try self.windows.get_exe();
        }
    }

    pub fn kill_all(self: *Self) Errors!void {
        if (comptime builtin.target.os.tag == .linux) {
            return try self.linux.kill_all();
        }
        if (comptime builtin.target.os.tag == .macos) {
            return try self.macos.kill_all();
        }
        if (comptime builtin.target.os.tag == .windows) {
            return try self.windows.kill_all();
        }
    }

    pub fn set_all_status(
        self: *Self,
        status: CpuStatus
    ) Errors!void {
        if (comptime builtin.target.os.tag == .linux) {
            return try self.linux.set_all_status(status);
        }
        if (comptime builtin.target.os.tag == .macos) {
            return try self.macos.set_all_status(status);
        }
    }

    pub fn limit_memory(self: *Self, limit: usize) Errors!void {
        try log.printdebug("Limiting memory pid: {d} to {d} bytes.", .{self.get_pid(), limit});
        if (comptime builtin.target.os.tag == .linux) {
            return try self.linux.limit_memory(limit);
        }
        if (comptime builtin.target.os.tag == .macos) {
            return try self.macos.limit_memory(limit);
        }
    }
};
