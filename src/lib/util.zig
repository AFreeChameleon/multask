const libc = @import("./c.zig").libc;
const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const util = @import("./util.zig");
const taskproc = @import("./task/process.zig");
const Monitoring = taskproc.Monitoring;

const log = @import("./log.zig");

const t = @import("./task/index.zig");
const TaskId = t.TaskId;

const tm = @import("./task/manager.zig");
const TaskManager = tm.TaskManager;
const Tasks = tm.Tasks;
const Stats = @import("./task/stats.zig").Stats;

const e = @import("./error.zig");
const Errors = e.Errors;

pub const gpa = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;
// var heap = std.heap.DebugAllocator(.{
//     .safety = true,
//     .retain_metadata = true,
//     .verbose_log = false,
//     .never_unmap = true
// }){};
// pub const gpa = heap.allocator();

pub const Pid = switch (builtin.target.os.tag) {
    .linux => i32,
    .macos => i32,
    .windows => u32,
    else => e.Errors.InvalidOs
};

// Linux
pub const Pgrp = switch (builtin.target.os.tag) {
    .linux, .windows => i32,
    .macos => u32,
    else => e.Errors.InvalidOs
};
pub const Sid = i32;

// 4096 is the max line length for the terminal
pub const MAX_TERM_LINE_LENGTH = 4096;

pub const SysTimes = struct {
    utime: u64,
    stime: u64
};

pub const MemLimit = usize;
pub const CpuLimit = usize;
pub const ForkFlags = struct {
    memory_limit: ?MemLimit,
    cpu_limit: ?CpuLimit,
    interactive: ?bool,
    persist: ?bool,
    update_envs: bool,
    no_run: bool = false
};

pub fn file_exists(file: std.fs.File) bool {
    const stat = file.stat()
        catch return false;
    return stat.kind == .file;
}

pub fn dir_exists(dir: std.fs.Dir) bool {
    const stat = dir.stat()
        catch return false;
    return stat.kind == .directory;
}

/// Copying string using an allocator
pub fn strdup(val: []const u8, cust_err: Errors) Errors![]u8 {
    return gpa.dupe(u8, val)
        catch |err| return e.verbose_error(err, cust_err);
}

/// Convert percent to human readable format to 2 decimal places
pub fn get_readable_cpu_usage(buf: []u8, usage: f64) Errors![]const u8 {
    const precise_cpu_usage = std.fmt.formatFloat(
        buf,
        usage,
        .{ .precision = 2, .mode = .decimal }
    ) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
    return precise_cpu_usage;
}

/// Convert time in seconds to human readable format
pub fn get_readable_runtime(buf: []u8, secs: u64) Errors![]const u8 {
    const seconds: u64 = @mod(secs, 60);
    const minutes: u64 = @mod(@divTrunc(secs, 60), 60);
    const hours: u64 = @divTrunc(@divTrunc(secs, 60), 60);
    const runtime = std.fmt.bufPrint(
        buf, "{d}h {d}m {d}s", .{
            hours, minutes, seconds
        }
    ) catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);
    return runtime;
}

// binary memory is 1024
// file memory is 1000
const SUFFIX: [9][]const u8 = .{"B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"};
const UNIT: f64 = 1000.0;
/// Convert memory in bytes to human readable format
/// Would recommend a 128 char buffer
pub fn get_readable_memory(buf: []u8, bytes: u64) Errors![]const u8 {
    if (bytes == 0) {
        @memcpy(buf[0..3], "0 B");
        return buf[0..3];
    }

    const float_bytes = @as(f64,
        @floatFromInt(bytes)
    );

    // Log 10 returns how much youd need to bring 10 to the power of to get that number
    // e.g log10(1000) == 3 (10^3 == 1000)
    const base: f64 = std.math.log10(float_bytes) / std.math.log10(UNIT);
    // This is to see how much should I lower 1000 (UNIT) by the power of
    // the decimal point in base to get the 1 digit number
    const num_result = std.math.pow(f64, UNIT, base - std.math.floor(base));

    var format_buf: [std.fmt.format_float.min_buffer_size]u8 = undefined;
    var result = std.fmt.formatFloat(
        &format_buf, num_result, .{.precision = 1, .mode = .decimal}
    ) catch |err| return e.verbose_error(err, error.FailedToGetProcessMemory);
    if (std.mem.eql(u8, result[result.len - 2..], ".0")) {
        result = result[0..result.len - 2];
    }

    const int_floor_base: usize = @intFromFloat(std.math.floor(base));
    if (int_floor_base > SUFFIX.len) {
        return error.FailedToGetProcessMemory;
    }

    const result_suff = std.fmt.bufPrint(
        buf, "{s} {s}", .{result, SUFFIX[@as(usize, int_floor_base)]}
    ) catch |err| return e.verbose_error(
        err, error.FailedToGetProcessMemory
    );
    return result_suff;
}

/// Gets length of entries in hashmap
pub fn get_map_length(comptime T: type, map: T) usize {
    var length: usize = 0;
    
    // Iterate through the internal entries of the AutoHashMap
    var it = map.iterator();
    while (it.next()) |_| {
        length += 1;
    }

    return length;
}

pub const TaskArgs = struct {
    ids: ?[]TaskId = null,
    namespaces: ?[][]u8 = null,
    parsed: bool = false,

    pub fn deinit(self: *TaskArgs) void {
        if (self.ids != null) {
            util.gpa.free(self.ids.?);
        }
        if (self.namespaces != null) {
            // Don't free each slice because the args are freed at the end of the program
            util.gpa.free(self.namespaces.?);
        }
    }
};

pub fn parse_cmd_vals(vals: [][]u8, tasks: *Tasks) Errors!TaskArgs {
    var ns = std.ArrayList([]u8).init(gpa);
    defer ns.deinit();
    var ids = std.ArrayList(TaskId).init(gpa);
    defer ids.deinit();

    for (vals) |arg| {
        if (is_number(arg)) {
            const id = std.fmt.parseInt(TaskId, arg, 10)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
            if (std.mem.indexOfScalar(TaskId, tasks.task_ids, id) == null) {
                return error.TaskNotExists;
            }
            ids.append(id)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
        } else if (std.mem.eql(u8, arg, "all")) {
            ids.appendSlice(tasks.task_ids)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
        } else {
            const ns_ids = tasks.namespaces.get(arg);
            if (ns_ids == null) return error.NamespaceNotExists;

            // checking if namespace is already parsed
            var exists = false;
            for (ns.items) |val| {
                if (std.mem.eql(u8, val, arg)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                ns.append(arg)
                    catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
            }

            for (ns_ids.?) |id| {
                if (count_occurrences(TaskId, &ids.items, id) == 0) {
                    ids.append(id)
                        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
                }
            }
        }
    }
    
    return TaskArgs {
        .ids = try unique_array(TaskId, ids.items),
        .namespaces = ns.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed),
        .parsed = true
    };
}

/// Counts occurrences an item is in a slice
pub fn count_occurrences(comptime T: type, list: *[]T, value: T) u32 {
    var count: u32 = 0;
    for (list.*) |item| {
        if (item == value) {
            count += 1;
        }
    }
    return count;
}

const supported_shells: [3][]const u8 = .{"zsh", "sh", "bash"};
/// FREE THIS
/// Gets path to shell (using the $SHELL env var)
pub fn get_shell_path() Errors![]u8 {
    if (comptime builtin.target.os.tag == .windows) {
        return try util.strdup("cmd", error.InvalidShell);
    } else {
        const shell = std.process.getEnvVarOwned(gpa, "SHELL")
            catch |err| return e.verbose_error(err, error.InvalidShell);
        inline for (supported_shells) |sh| {
            const shell_name = shell[(shell.len - sh.len)..];
            if (std.mem.eql(u8, shell_name, sh)) {
                return shell;
            }
        }
        try log.printdebug("Unsupported shell used: {s}, using bash", .{shell});
        gpa.free(shell);
        return try util.strdup("/bin/bash", error.InvalidShell);
    }
}

/// Cross platform way of getting current pid
pub fn get_pid() Pid {
    if (comptime builtin.target.os.tag == .linux) {
        return std.os.linux.getpid();
    }
    if (comptime builtin.target.os.tag == .macos) {
        return libc.getpid();
    }
    if (comptime builtin.target.os.tag == .windows) {
        const pid: Pid = std.os.windows.GetCurrentProcessId();
        return pid;
    }
}

pub fn is_number(val: []const u8) bool {
    for (val) |char| {
        if (!std.ascii.isDigit(char)) {
            return false;
        }
    }
    return true;
}

pub fn is_alphabetic(val: []const u8) bool {
    for (val) |char| {
        if (!std.ascii.isAlphabetic(char)) {
            return false;
        }
    }
    return true;
}

/// Removes id from the namespace
pub fn remove_id_from_namespace(
    id: TaskId,
    ns: *std.StringHashMap([]TaskId)
) Errors!void {
    var keys = ns.keyIterator();
    while (keys.next()) |key| {
        const val = ns.get(key.*);
        if (val == null) continue;
        if (std.mem.indexOfScalar(TaskId, val.?, id) == null) {
            continue;
        }
        defer util.gpa.free(val.?);

        const new_val_len = val.?.len - 1;
        // Delete namespace if no more ids in it
        if (new_val_len <= 0) {
            const ret = ns.fetchRemove(key.*);
            if (ret != null) {
                util.gpa.free(ret.?.key);
            }
            continue;
        } else {
            var filtered_ids = util.gpa.alloc(TaskId, new_val_len)
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedDelete);
            var idx: usize = 0;
            for (val.?) |tid| {
                if (tid == id) {
                    continue;
                }
                if (idx > filtered_ids.len - 1) {
                    return error.TasksNamespacesFileFailedDelete;
                }
                filtered_ids[idx] = tid;
                idx += 1;
            }
            ns.put(
                key.*,
                filtered_ids
            ) catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedDelete);
        }
    }
}

const ValidateFlags = struct {
    memory_limit: ?MemLimit,
    cpu_limit: ?CpuLimit,
};
pub fn validate_flags(flags: ValidateFlags) Errors!void {
    if (flags.cpu_limit != null) {
        if (flags.cpu_limit.? != 0 and (flags.cpu_limit.? < 1 or flags.cpu_limit.? > 99)) {
            return error.CpuLimitValueInvalid;
        }
    }
    if (flags.memory_limit != null) {
        if (flags.memory_limit.? != 0 and flags.memory_limit.? < 0) {
            return error.MemoryLimitValueInvalid;
        }
    }
}

/// FREE THIS
pub fn unique_array(comptime T: type, arr: []T) Errors![]T {
    var unique = std.ArrayList(T).init(gpa);
    defer unique.deinit();
    for (arr) |item| {
        if (std.mem.indexOfScalar(T, unique.items, item) == null) {
            unique.append(item)
                catch |err| return e.verbose_error(err, error.InternalUtilError);
        }
    }
    return unique.toOwnedSlice()
        catch |err| return e.verbose_error(err, error.InternalUtilError);
}

pub fn read_monitoring_from_string(val: []const u8) Errors!Monitoring {
    if (std.mem.eql(u8, val, "deep")) {
        return Monitoring.Deep;
    }
    if (std.mem.eql(u8, val, "shallow")) {
        return Monitoring.Shallow;
    }
    return error.InvalidArgument;
}

pub fn get_mlt_exe_path() Errors![]u8 {
    const exe_path = std.fs.selfExePathAlloc(util.gpa)
        catch |err| return e.verbose_error(err, error.FailedToGetStartupDetails);

    return exe_path;
}

test "lib/util.zig" {
    std.debug.print("\n--- lib/util.zig ---\n", .{});
}

test "Readable memory: Parse 1 to 1 B" {
    std.debug.print("Readable memory: Parse 1 to 1 B\n", .{});
    var buf: [128]u8 = undefined;
    const res = try util.get_readable_memory(&buf, 1);
    try std.testing.expect(std.mem.eql(u8, res, "1 B"));
}

test "Readable memory: Parse 1024 to 1 KiB" {
    std.debug.print("Readable memory: Parse 1024 to 1 KiB\n", .{});
    var buf: [128]u8 = undefined;
    const res = try util.get_readable_memory(&buf, 1000);
    try std.testing.expect(std.mem.eql(u8, res, "1 KB"));
}

test "Readable memory: Parse 1500 to 1.5 KiB" {
    std.debug.print("Readable memory: Parse 1500 to 1.5 KiB\n", .{});
    var buf: [128]u8 = undefined;
    const res = try util.get_readable_memory(&buf, 1500);
    try std.testing.expect(std.mem.eql(u8, res, "1.5 KB"));
}

test "Read monitoring `deep` from string" {
    std.debug.print("Read monitoring `deep` from string\n", .{});
    const deep = "deep";
    const m = try read_monitoring_from_string(deep);
    try expect(m == Monitoring.Deep);
}

test "Read monitoring `shallow` from string" {
    std.debug.print("Read monitoring `shallow` from string\n", .{});
    const shallow = "shallow";
    const m = try read_monitoring_from_string(shallow);
    try expect(m == Monitoring.Shallow);
}

test "Read monitoring error from string" {
    std.debug.print("Read monitoring error from string\n", .{});
    const err = "err";
    const m = read_monitoring_from_string(err);
    try expect(m == error.InvalidArgument);
}

test "Remove id from namespace" {
    std.debug.print("Remove id from namespace\n", .{});
    var ns: std.StringHashMap([]TaskId) = std.StringHashMap([]TaskId).init(util.gpa);
    const ns_name = "testns";
    defer {
        const v = ns.get(ns_name);
        util.gpa.free(v.?);
        ns.deinit();
    }
    var task_ids = try util.gpa.alloc(TaskId, 2);

    task_ids[0] = 1;
    task_ids[1] = 2;

    try ns.put(ns_name, task_ids[0..]);
    try remove_id_from_namespace(1, &ns);
    try expect(ns.get(ns_name).?[0] == 2);
}

test "Parse cmd values with id and namespace" {
    std.debug.print("Parse cmd values with id and namespace\n", .{});
    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var nsone_task_ids = [_]TaskId{3, 4};
    try ns.put("nsone", &nsone_task_ids);

    var id1 = [_]u8{'1'};
    var id2 = [_]u8{'2'};
    var ns1 = [_]u8{'n', 's', 'o', 'n', 'e'};
    var values = [_][]u8{&id1, &id2, &ns1};

    var all_task_ids = [_]TaskId{1, 2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };


    var args = try parse_cmd_vals(&values, &tasks);
    defer args.deinit();
    try expect(args.ids.?[0] == 1);
    try expect(args.ids.?[1] == 2);
    try expect(std.mem.eql(u8, args.namespaces.?[0], "nsone"));
}

test "Parse cmd values with missing id" {
    std.debug.print("Parse cmd values with missing id\n", .{});
    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var id1 = [_]u8{'1'};
    var values = [_][]u8{&id1};

    var all_task_ids = [_]TaskId{2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };


    const res = parse_cmd_vals(&values, &tasks);
    try expect(res == error.TaskNotExists);
}

test "Parse cmd values with missing namespace" {
    std.debug.print("Parse cmd values with missing namespace\n", .{});
    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var nsone = [_]u8{'n', 's', 'o', 'n', 'e'};
    var values = [_][]u8{&nsone};

    var all_task_ids = [_]TaskId{};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };


    const res = parse_cmd_vals(&values, &tasks);
    try expect(res == error.NamespaceNotExists);
}

test "Parse cmd values with duplicate ids" {
    std.debug.print("Parse cmd values with duplicate ids\n", .{});
    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var id1 = [_]u8{'1'};
    var id1again = [_]u8{'1'};
    var id1againagain = [_]u8{'1'};
    var values = [_][]u8{&id1, &id1again, &id1againagain};

    var all_task_ids = [_]TaskId{1};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };

    var res = try parse_cmd_vals(&values, &tasks);
    defer res.deinit();
    try expect(res.ids.?.len == 1);
    try expect(res.ids.?[0] == 1);
}

test "Parse cmd values with duplicate namespace" {
    std.debug.print("Parse cmd values with duplicate namespace\n", .{});
    var ns: tm.TNamespaces = std.StringHashMap([]TaskId).init(util.gpa);
    defer ns.deinit();

    var nsone_task_ids = [_]TaskId{3, 4};
    try ns.put("nsone", &nsone_task_ids);

    var nsone = [_]u8{'n', 's', 'o', 'n', 'e'};
    var nsoneagain = [_]u8{'n', 's', 'o', 'n', 'e'};
    var values = [_][]u8{&nsone, &nsoneagain};


    var all_task_ids = [_]TaskId{1, 2, 3, 4};
    var tasks = Tasks {
        .namespaces = ns,
        .task_ids = &all_task_ids
    };


    var res = try parse_cmd_vals(&values, &tasks);
    defer res.deinit();

    try expect(res.namespaces.?.len == 1);
    try expect(std.mem.eql(u8, res.namespaces.?[0], "nsone"));
    try expect(res.ids.?.len == 2);
}
