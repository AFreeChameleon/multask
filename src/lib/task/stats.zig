const util = @import("../util.zig");

pub const Stats = struct {
    const Self = @This();

    command: []const u8,
    cwd: []const u8,
    memory_limit: util.MemLimit,
    cpu_limit: util.CpuLimit,
    persist: bool,

    pub fn deinit(self: *Self) void {
        util.gpa.free(self.command);
        util.gpa.free(self.cwd);
    }
};
