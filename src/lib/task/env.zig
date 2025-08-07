const std = @import("std");
const expect = std.testing.expect;
const util = @import("../util.zig");
const Lengths = util.Lengths;

const TaskId = @import("./index.zig").TaskId;

const log = @import("../log.zig");

const e = @import("../error.zig");
const Errors = e.Errors;

pub const ScanMode = enum { key, value };

pub const JSON_Env = struct {
    map_string: []u8,

    pub fn deinit(self: *const JSON_Env) void {
        util.gpa.free(self.map_string);
    }

    pub fn clone(self: *const JSON_Env) Errors!JSON_Env {
        return JSON_Env {
            .map_string = try util.strdup(self.map_string, error.FailedToGetEnvs)
        };
    }

    /// Format is <KEY>=<VALUE>;
    /// this means any ; in the value itself will need to be escaped
    pub fn to_map(self: *const JSON_Env) Errors!std.process.EnvMap {
        var map = std.process.EnvMap.init(util.gpa);

        var mode: ScanMode = .key;
        var key_list = std.ArrayList(u8).init(util.gpa);
        defer key_list.deinit();
        var value_list = std.ArrayList(u8).init(util.gpa);
        defer value_list.deinit();
        var escaping = false;
        for (self.map_string, 0..) |char, i| {
            // For windows
            if (char == '=' and key_list.items.len > 0) {
                mode = .value;
                continue;
            }
            if (
                char == '\\' and
                i + 1 < self.map_string.len and
                self.map_string[i + 1] == ';'
            ) {
                escaping = true;
                continue;
            }
            if (char == ';' and !escaping) {
                const key = key_list.toOwnedSlice()
                    catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
                defer util.gpa.free(key);
                const value = value_list.toOwnedSlice()
                    catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
                defer util.gpa.free(value);

                map.put(key, value)
                    catch |err| return e.verbose_error(err, error.TaskFileFailedRead);

                mode = .key;
                continue;
            }

            // Writing to actual vars here
            if (mode == .key) {
                key_list.append(char)
                    catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
                escaping = false;
                continue;
            }
            if (mode == .value) {
                value_list.append(char)
                    catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
                escaping = false;
                continue;
            }
        }

        return map;
    }

};

pub fn serialise(map: std.process.EnvMap) Errors!JSON_Env {
    var itr = map.iterator();
    var string_list = std.ArrayList(u8).init(util.gpa);
    defer string_list.deinit();

    while (itr.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (key.len == 0) {
            try log.printdebug("Empty key.", .{});
            return error.FailedToGetEnvs;
        }
        const key_semicolon_count = std.mem.count(u8, key, ";");
        const value_semicolon_count = std.mem.count(u8, value, ";");
        // adding extra bytes for the extra \ in front of the semicolon
        const escaped_key = util.gpa.alloc(u8, key.len + key_semicolon_count)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        defer util.gpa.free(escaped_key);
        const escaped_value = util.gpa.alloc(u8, value.len + value_semicolon_count)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        defer util.gpa.free(escaped_value);
        _ = std.mem.replace(u8, key, ";", "\\;", escaped_key);
        _ = std.mem.replace(u8, value, ";", "\\;", escaped_value);

        const string = std.fmt.allocPrint(util.gpa, "{s}={s};", .{escaped_key, escaped_value})
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        defer util.gpa.free(string);

        string_list.appendSlice(string)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
    }

    const json_env = JSON_Env {
        .map_string = string_list.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs)
        };
    return json_env;
}

pub fn add_multask_taskid_to_map(map: *std.process.EnvMap, task_id: TaskId) Errors!void {
    var buf: [Lengths.TINY]u8 = std.mem.zeroes([Lengths.TINY]u8);
    const val = std.fmt.bufPrint(&buf, "{d}", .{task_id})
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
    map.put("MULTASK_TASK_ID", val)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
}

test "lib/task/env.zig" {
    std.debug.print("\n--- lib/task/env.zig ---\n", .{});
}

test "Deserialising env list" {
    std.debug.print("Deserialising env list\n", .{});

    const map_str = try std.fmt.allocPrint(util.gpa, "KEY=VAL;KEY2=VAL2;", .{});

    const json_env = JSON_Env {
        .map_string = map_str
    };
    defer json_env.deinit();

    var map = try json_env.to_map();
    defer map.deinit();

    const env1 = map.get("KEY");
    try expect(env1 != null);
    try expect(std.mem.eql(u8, env1.?, "VAL"));

    const env2 = map.get("KEY2");
    try expect(env2 != null);
    try expect(std.mem.eql(u8, env2.?, "VAL2"));
}

test "Deserialising env list with escaped semicolon" {
    std.debug.print("Deserialising env list with escaped semicolon\n", .{});

    const map_str = try std.fmt.allocPrint(util.gpa, "KEY\\;=VAL\\;;KEY2=VAL2;", .{});

    const json_env = JSON_Env {
        .map_string = map_str
    };
    defer json_env.deinit();

    var map = try json_env.to_map();
    defer map.deinit();

    const env1 = map.get("KEY;");
    try expect(env1 != null);
    try expect(std.mem.eql(u8, env1.?, "VAL;"));

    const env2 = map.get("KEY2");
    try expect(env2 != null);
    try expect(std.mem.eql(u8, env2.?, "VAL2"));
}

test "Deserialising env list with pseudo env variable (only on windows)" {
    std.debug.print("Deserialising env list with pseudo env variable (only on windows)\n", .{});

    const map_str = try std.fmt.allocPrint(util.gpa, "=PSEUDO=VAL;KEY2=VAL2;", .{});

    const json_env = JSON_Env {
        .map_string = map_str
    };
    defer json_env.deinit();

    var map = try json_env.to_map();
    defer map.deinit();

    const env1 = map.get("=PSEUDO");
    try expect(env1 != null);
    try expect(std.mem.eql(u8, env1.?, "VAL"));

    const env2 = map.get("KEY2");
    try expect(env2 != null);
    try expect(std.mem.eql(u8, env2.?, "VAL2"));
}

test "Serialising env" {
    std.debug.print("Serialising env\n", .{});
    var map = std.process.EnvMap.init(util.gpa);
    defer map.deinit();

    try map.put("KEY", "VALUE");
    try map.put("KEY2", "VALUE2");

    const json = try serialise(map);
    defer json.deinit();
    
    try expect(std.mem.eql(u8, json.map_string, "KEY=VALUE;KEY2=VALUE2;"));
}

test "Serialising env with escaped semicolon" {
    std.debug.print("Serialising env with escaped semicolon\n", .{});
    var map = std.process.EnvMap.init(util.gpa);
    defer map.deinit();

    try map.put("KE;Y", "V;ALUE");

    const json = try serialise(map);
    defer json.deinit();
    
    try expect(std.mem.eql(u8, json.map_string, "KE\\;Y=V\\;ALUE;"));
}
