const std = @import("std");
const Task = @import("./index.zig").Task;

const util = @import("../util.zig");
const Lengths = util.Lengths;

const e = @import("../error.zig");
const Errors = e.Errors;

const JSON_CpuResource = struct {
    pid: util.Pid,
    percentage: f64
};
pub const JSON_Resources = struct {
    cpu: []JSON_CpuResource,

    pub fn deinit(self: *const JSON_Resources) void {
        util.gpa.free(self.cpu);
    }

    pub fn to_struct(self: *const JSON_Resources) Errors!Resources {
        var resources = Resources.init();

        for (self.cpu) |res| {
            resources.cpu.put(res.pid, res.percentage)
                catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
        }

        return resources;
    }

    pub fn clone(self: *const JSON_Resources) Errors!JSON_Resources {
        return JSON_Resources {
            .cpu = util.gpa.dupe(JSON_CpuResource, self.cpu)
                catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage)
        };
    }
};

pub const Resources = struct {
    cpu: std.AutoHashMap(util.Pid, f64) = undefined,

    pub fn init() Resources {
        return Resources {
            .cpu = std.AutoHashMap(util.Pid, f64).init(util.gpa)
        };
    }

    pub fn deinit(self: *Resources) void {
        self.cpu.clearAndFree();
        self.cpu.deinit();
    }

    pub fn clone(self: *const Resources) Resources {
        return Resources {
            .cpu = self.cpu.clone()
                catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage)
        };
    }

    pub fn to_json(self: *const Resources) Errors!JSON_Resources {
        var json = std.ArrayList(JSON_CpuResource).init(util.gpa);
        defer json.deinit();
        var key_itr = self.cpu.keyIterator();
        while (key_itr.next()) |key| {
            const percentage = self.cpu.get(key.*);
            if (percentage != null) {
                json.append(JSON_CpuResource {
                    .pid = key.*,
                    .percentage = percentage.?
                }) catch |err| return e.verbose_error(err, error.FailedToSetCpuUsage);
            }
        }
        return JSON_Resources {
            .cpu = json.toOwnedSlice()
                catch |err| return e.verbose_error(err, error.FailedToSetCpuUsage)
        };
    }

    pub fn set_cpu_usage(self: *Resources, task: *Task) Errors!void {
        try self.clear_cpu();

        var res = try get_resources(task);
        defer res.deinit();
        var key_itr = res.cpu.keyIterator();
        while (key_itr.next()) |key| {
            const val = res.cpu.get(key.*);
            if (val == null) {
                return error.FailedToSetCpuUsage;
            }
            self.cpu.put(key.*, val.?)
                catch |err| return e.verbose_error(err, error.FailedToSetCpuUsage);
        }
    }

    fn clear_cpu(self: *Resources) Errors!void {
        var key_itr = self.cpu.keyIterator();
        while (key_itr.next()) |key| {
            _ = self.cpu.remove(key.*);
        }
    }

    fn get_resources(task: *Task) Errors!Resources {
        const json_res = task.files.read_file(JSON_Resources)
            catch |err| switch (err) {
                error.TaskFileFailedRead => return Resources.init(),
                else => return err
            };
        if (json_res == null) {
            return Resources.init();
        }
        defer json_res.?.deinit();
        const res = try json_res.?.to_struct();

        return res;
    }
};
