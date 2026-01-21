const std = @import("std");
const util = @import("../util.zig");
const Errors = @import("../error.zig").Errors;
const Monitoring = @import("./process.zig").Monitoring;

pub const Stats = struct {
    const Self = @This();

    command: []const u8,
    cwd: []const u8,
    memory_limit: util.MemLimit,
    cpu_limit: util.CpuLimit,
    persist: bool,
    monitoring: Monitoring,
    boot: bool,
    interactive: bool,

    pub fn deinit(self: *Self) void {
        util.gpa.free(self.command);
        util.gpa.free(self.cwd);
    }

    pub fn clone(self: *const Self) Errors!Self {
        const stats = Self {
            .command = try util.strdup(self.command, error.FailedToGetTaskStats),
            .cwd = try util.strdup(self.cwd, error.FailedToGetTaskStats),
            .memory_limit = self.memory_limit,
            .cpu_limit = self.cpu_limit,
            .persist = self.persist,
            .monitoring = self.monitoring,
            .boot = self.boot,
            .interactive = self.interactive
        };
        return stats;
    }
};
