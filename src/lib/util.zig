const libc = @import("./c.zig").libc;
const builtin = @import("builtin");
const std = @import("std");
const util = @import("./util.zig");

const log = @import("./log.zig");

const t = @import("./task/index.zig");
const TaskId = t.TaskId;
const TaskManager = t.TaskManager;

const e = @import("./error.zig");
const Errors = e.Errors;


pub const gpa = std.heap.c_allocator;

// pub const Pid = if (builtin.os.tag == .windows) std.os.windows.HANDLE else c_int;
pub const Pid = if (builtin.target.os.tag == .windows) u32 else i32;

// 4096 is the max line length for the terminal
pub const MAX_TERM_LINE_LENGTH = 4096;

/// Standard for array length
pub const Lengths = struct {
    pub const TINY: usize = 32;
    pub const SMALL: usize = 64;
    pub const MEDIUM: usize = 128;
    pub const LARGE: usize = 1024;
    pub const HUGE: usize = 4096;

    pub const TASK_LIMIT: usize = 256;
};
pub const MemLimit = usize;
pub const CpuLimit = usize;
pub const ForkFlags = struct {
    memory_limit: MemLimit,
    cpu_limit: CpuLimit,
    interactive: bool,
    persist: bool,
};

/// Strings to be put into process' files
pub const FileStrings = struct {
    processes: [Lengths.LARGE]u8,
    usage: [Lengths.LARGE]u8,
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
pub fn get_readable_cpu_usage(usage: f64) Errors![]const u8 {
    var precise_cpu_buf: [64]u8 = undefined;
    const precise_cpu_usage = std.fmt.formatFloat(
        &precise_cpu_buf,
        usage,
        .{ .precision = 2, .mode = .decimal }
    ) catch |err| return e.verbose_error(err, error.FailedToGetCpuUsage);
    return try util.strdup(precise_cpu_usage, error.FailedToGetCpuUsage);
}

/// Convert time in seconds to human readable format
pub fn get_readable_runtime(secs: u64) Errors![]const u8 {
    const seconds: u64 = @mod(secs, 60);
    const minutes: u64 = @mod(@divTrunc(secs, 60), 60);
    const hours: u64 = @divTrunc(@divTrunc(secs, 60), 60);
    var buf: [128]u8 = std.mem.zeroes([128]u8);
    const runtime = std.fmt.bufPrint(
        &buf, "{d}h {d}m {d}s", .{
            hours, minutes, seconds
        }
    ) catch |err| return e.verbose_error(err, error.FailedToGetProcessRuntime);
    return try util.strdup(runtime, error.FailedToGetProcessRuntime);
}

// binary memory is 1024
// file memory is 1000
const SUFFIX: [9][]const u8 = .{"B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"};
const UNIT: f64 = 1024.0;
/// Convert memory in bytes to human readable format
pub fn get_readable_memory(bytes: u64) Errors![]const u8 {
    if (bytes == 0) {
        return "0 B";
    }

    const float_bytes = @as(f64,
        @floatFromInt(bytes)
    );
    const base: f64 = std.math.log10(float_bytes) / std.math.log10(UNIT);
    const num_result = std.math.pow(f64, UNIT, base - std.math.floor(base));
    var format_buf: [128]u8 = std.mem.zeroes([128]u8);
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

    var result_suff_buf: [128]u8 = std.mem.zeroes([128]u8);
    const result_suff = std.fmt.bufPrint(
        &result_suff_buf, "{s} {s}", .{result, SUFFIX[@as(usize, int_floor_base)]}
    ) catch |err| return e.verbose_error(
        err, error.FailedToGetProcessMemory
    );
    return try util.strdup(result_suff, error.FailedToGetProcessMemory);
}

/// Colouring strings with ANSI escape codes
pub fn colour_string(str: []const u8, r: u8, g: u8, b: u8) Errors![]const u8 {
    const total_len = str.len + 64;
    const buf = gpa.alloc(u8, total_len)
        catch |err| return e.verbose_error(err, error.InternalLoggingFailed);
    defer gpa.free(buf);
    const final_str = std.fmt.bufPrint(
        buf,
        "\x1B[38;2;{d};{d};{d}m{s}\x1B[0m",
        .{r, g, b, str}
    ) catch |err| return e.verbose_error(err, error.InternalLoggingFailed);

    return try util.strdup(final_str, error.InternalLoggingFailed);
}

/// Remove ANSI codes starting with 0x1B[ and ending with 'm'
pub fn strip_ansi_codes(str: []const u8) Errors![]u8 {
    var start_idx: i32 = -1;

    var str_buf = gpa.alloc(u8, str.len)
        catch |err| return e.verbose_error(err, error.InternalLoggingFailed);
    var str_buf_idx: usize = 0;
    defer gpa.free(str_buf);

    for (str, 0..) |char, i| {
        // These two if statements take care of the "0x1B[" characters
        if (start_idx + 1 == i and char == '[') {
            continue;
        }
        if (char == 0x1B) {
            start_idx = @intCast(i);
            continue;
        }

        // If we're in the start esc sequence
        if (start_idx != -1) {
            if (char == 'm') {
                start_idx = -1;
                continue;
            } else if (
                char == ';' or
                std.ascii.isDigit(char)
            ) {
                continue;
                
            } else start_idx = -1;
        }
        str_buf[str_buf_idx] = char;
        str_buf_idx += 1;
    }
    return try strdup(str_buf[0..str_buf_idx], error.InternalLoggingFailed);
}

/// Zig implementation of:
/// [https://github.com/sindresorhus/string-width/blob/main/index.js]
/// Missing east asian width, probably won't implement that (sorry east asia)
/// I'll probably have to write tests for this
pub fn get_string_visual_length(str: []const u8) Errors!u32 {
    var width: u32 = 0;
    const stripped_str = try strip_ansi_codes(str);
    for (stripped_str) |char| {
        // Ignore control characters
        if (
            char <= 0x1F or
            (char >= 0x7F and char <= 0x9F)
        ) continue;

        // Ignore zero-width characters
        if (
            (char >= 0x20_0B and char <= 0x20_0F) or
            char == 0xFE_FF
        ) continue;


        // Ignore combining characters
        if (
            (char >= 0x3_00 and char <= 0x3_6F) or // Combining diacritical marks
            (char >= 0x1A_B0 and char <= 0x1A_FF) or // Combining diacritical marks extended
            (char >= 0x1D_C0 and char <= 0x1D_FF) or // Combining diacritical marks supplement
            (char >= 0x20_D0 and char <= 0x20_FF) or // Combining diacritical marks for symbols
            (char >= 0xFE_20 and char <= 0xFE_2F) // Combining half marks
        ) continue;

        // Ignore surrogate pairs
        if (char >= 0xD8_00 and char <= 0xDF_FF) continue;

        // Ignore variation selectors
        if (char >= 0xFE_00 and char <= 0xFE_0F) continue;

        width += 1;
    }
    return width;
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
    parsed: bool = false
};
/// Converting parsed args to ids and namespaces
pub fn parse_cmd_args(args: [][*:0]u8) Errors!TaskArgs {
    var ns = std.ArrayList([]u8).init(util.gpa);
    defer ns.deinit();
    var ids = std.ArrayList(TaskId).init(util.gpa);
    defer ids.deinit();
    const namespaces = try TaskManager.get_namespaces();

    // Starting from 1 to ignore the command e.g. "start"
    for (args[1..]) |arg_ptr| {
        const arg: []u8 = std.mem.span(@as([*:0]u8, arg_ptr));
        if (is_number(arg)) {
            const id = std.fmt.parseInt(TaskId, arg, 10)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
            ids.append(id)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
        } else {
            const ns_ids = namespaces.get(arg);
            if (ns_ids == null) return error.NamespaceNotExists;
            ns.append(arg)
                catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
            for (ns_ids.?) |id| {
                if (count_occurrences(TaskId, &ids.items, id) == 0) {
                    ids.append(id)
                        catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed);
                }
            }
        }
    }
    return TaskArgs {
        .ids = ids.toOwnedSlice()
            catch |err| return e.verbose_error(err, error.ParsingCommandArgsFailed),
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
// Gets path to shell (using the $SHELL env var)
pub fn get_shell_path() Errors![]u8 {
    if (comptime builtin.target.os.tag == .windows) {
        return try util.strdup("cmd", error.InvalidShell);
    } else {
        const shell = std.process.getEnvVarOwned(util.gpa, "SHELL")
            catch |err| return e.verbose_error(err, error.InvalidShell);
        for (supported_shells) |sh| {
            const shell_name = shell[(shell.len - sh.len)..];
            if (std.mem.eql(u8, shell_name, sh)) {
                return shell;
            }
        }
        try log.printdebug("Unsupported shell used: {s}, using bash", .{shell});
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

        var filtered_ids = std.ArrayList(TaskId).init(util.gpa);
        defer filtered_ids.deinit();
        for (val.?) |tid| {
            if (tid != id) {
                filtered_ids.append(tid)
                    catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedDelete);
            }
        }
        // Delete namespace if no more ids in it
        if (filtered_ids.items.len == 0) {
            if (!ns.remove(key.*)) {
                return error.TasksNamespacesFileFailedDelete;
            }
        } else {
            ns.put(
                key.*,
                filtered_ids.toOwnedSlice()
                catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedDelete)
            ) catch |err| return e.verbose_error(err, error.TasksNamespacesFileFailedDelete);
        }
    }
}

const ValidateFlags = struct {
    memory_limit: MemLimit,
    cpu_limit: CpuLimit,
};
pub fn validate_flags(flags: ValidateFlags) Errors!void {
    if (flags.cpu_limit != 0 and (flags.cpu_limit < 1 or flags.cpu_limit > 99)) {
        return error.CpuLimitValueInvalid;
    }
    if (flags.memory_limit != 0 and flags.memory_limit < 0) {
        return error.MemoryLimitValueInvalid;
    }
}

pub fn unique_array(comptime T: type, arr: []T) Errors![]T {
    var unique = std.ArrayList(T).init(util.gpa);
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

pub fn save_stats(task: *t.Task, flags: *const ForkFlags) Errors!void {
    try util.validate_flags(.{
        .memory_limit = flags.memory_limit,
        .cpu_limit = flags.cpu_limit
    });

    // Have to refresh stats
    task.stats.cpu_limit = flags.cpu_limit;
    task.stats.memory_limit = flags.memory_limit;
    task.stats.persist = flags.persist;
    try task.files.write_stats_file(task.stats);
}
