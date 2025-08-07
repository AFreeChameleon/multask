const std = @import("std");
const expect = std.testing.expect;
const builtin = @import("builtin");
const util = @import("../util.zig");
const TaskId = @import("../task/index.zig").TaskId;
const Pid = util.Pid;
const e = @import("../error.zig");
const log = @import("../log.zig");
const Errors = e.Errors;
const WindowsProcess = @import("./process.zig").WindowsProcess;
const libc = @import("../c.zig").libc;
const ScanMode = @import("../task/env.zig").ScanMode;
const MULTASK_TASK_ID = [_]u16 {
    0, 'M', 'U', 'L', 'T', 'A', 'S', 'K', '_', 'T', 'A', 'S', 'K', '_', 'I', 'D', '='
};

const win = std.os.windows;
const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;
extern "ntdll" fn NtQueryInformationProcess(
    processHandle: win.HANDLE,
    processInformationClass: u32,
    processInformation: *anyopaque,
    processInformationLength: u32,
    returnLength: ?*u32,
) callconv(WINAPI) win.NTSTATUS;

// extern "kernel32" fn OpenProcess(
//     dwDesiredAccess: u32,
//     bInheritHandle: i32,
//     dwProcessId: u32,
// ) callconv(WINAPI) ?win.HANDLE;

// const PROCESS_QUERY_INFORMATION: win.DWORD = 0x0400;
// const PROCESS_VM_READ: win.DWORD = 0x0010;

const UNICODE_STRING = extern struct {
    Length: u16,
    MaximumLength: u16,
    Buffer: win.LPWSTR
};

const RTL_USER_PROCESS_PARAMETERS = extern struct {
    Reserved1: [16]u8,
    Reserved2: [10]?*anyopaque,
    ImagePathName: UNICODE_STRING,
    CommandLine: UNICODE_STRING,
    Environment: *anyopaque
};

const PEB = extern struct {
    BeingDebugged: u8,
    Reserved1: [2]u8,
    Reserved2: [1]u8,    
    Reserved3: [2]?*anyopaque,
    Ldr: ?*anyopaque,
    ProcessParameters: *RTL_USER_PROCESS_PARAMETERS 
};

const PROCESS_BASIC_INFORMATION = extern struct {
    Reserved1: ?*anyopaque,
    PebBaseAddress: *PEB,
    Reserved2: [2]?*anyopaque,
    UniqueProcessId: usize,
    Reserved3: ?*anyopaque,
};

fn read_memory(
    proc: win.HANDLE,
    addr: *const anyopaque,
    buf: []u8,
) Errors!void {
    var bytes_read: usize = 0;
    if (libc.ReadProcessMemory(proc, addr, buf.ptr, buf.len, &bytes_read) == 0) {
        try log.printdebug("Failed to read memory {d}.", .{libc.GetLastError()});
        return error.FailedToGetEnvs;
    }
}

pub fn proc_has_taskid_in_env(pid: Pid, task_id: TaskId) Errors!bool {
    const process_handle = libc.OpenProcess(libc.PROCESS_QUERY_INFORMATION | libc.PROCESS_VM_READ, win.FALSE, pid);
    if (process_handle == null) {
        try log.printdebug("Failed to get process handle {d} {any}.", .{libc.GetLastError(), process_handle});
        return error.FailedToGetEnvs;
    }
    defer _ = libc.CloseHandle(process_handle);

    var pbi: PROCESS_BASIC_INFORMATION = std.mem.zeroes(PROCESS_BASIC_INFORMATION);
    
    if (NtQueryInformationProcess(
        process_handle.?,
        0, // ProcessBasicInformation
        &pbi,
        @sizeOf(PROCESS_BASIC_INFORMATION),
        null
    ) != win.NTSTATUS.SUCCESS) {
        try log.printdebug("Failed to get pbi {d}.", .{libc.GetLastError()});
        return error.FailedToGetEnvs;
    }

    var peb_buf: [@sizeOf(PEB)]u8 = undefined;

    try read_memory(process_handle.?, pbi.PebBaseAddress, peb_buf[0..]);

    const peb: PEB = std.mem.bytesToValue(PEB, &peb_buf);

    var proc_params_buf: [@sizeOf(RTL_USER_PROCESS_PARAMETERS)]u8 = std.mem.zeroes([@sizeOf(RTL_USER_PROCESS_PARAMETERS)]u8);
    try read_memory(process_handle.?, peb.ProcessParameters, proc_params_buf[0..]);
    const params: RTL_USER_PROCESS_PARAMETERS = std.mem.bytesToValue(RTL_USER_PROCESS_PARAMETERS, &proc_params_buf);

    var env_block: [32768]u16 = std.mem.zeroes([32768]u16); // 64 KB
    try read_memory(process_handle.?, params.Environment, @as([*]u8, @ptrCast(&env_block))[0..@sizeOf(@TypeOf(env_block))]);

    const env_task_id = try find_task_id_from_wenv_block(env_block[0..]);
    if (env_task_id == null) {
        return false;
    }

    if (env_task_id.? == task_id) {
        return true;
    }

    return false;
}

fn find_task_id_from_wenv_block(wenv_block: []u16) Errors!?TaskId {
    const idx = std.mem.indexOf(u16, wenv_block, &MULTASK_TASK_ID);
    if (idx == null) {
        return null;
    }

    const start_idx = idx.? + MULTASK_TASK_ID.len; // Start scanning at the numbers
    var end_idx = idx.? + MULTASK_TASK_ID.len;
    while (wenv_block[end_idx] != 0) {
        if (end_idx > start_idx + 10) {
            return error.CorruptTaskIdEnvVariable;
        }
        end_idx += 1;
    }

    const str_task_id = try convert_wstring_to_string(wenv_block[start_idx..end_idx]);
    defer util.gpa.free(str_task_id);

    const trimmed_str_task_id = std.mem.trimRight(u8, str_task_id, &[1]u8{0});

    const task_id = std.fmt.parseInt(TaskId, trimmed_str_task_id, 10)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);

    return task_id;
}

/// FREE THIS
fn convert_wstring_to_string(wstr: []u16) Errors![]u8 {
    const utf8_len: usize = @intCast(libc.WideCharToMultiByte(libc.CP_UTF8, 0, wstr.ptr, -1, null, 0, null, null));
    if (utf8_len == 0) {
        return error.FailedToGetEnvs;
    }

    const utf8_str = util.gpa.alloc(u8, utf8_len)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);

    const result = libc.WideCharToMultiByte(libc.CP_UTF8, 0, wstr.ptr, -1, utf8_str.ptr, @intCast(utf8_len), null, null);
    if (result == 0) {
        return error.FailedToGetEnvs;
    }
    return utf8_str;
}

// DEINIT THIS
pub fn string_to_map(val: []const u8) Errors!std.process.EnvMap {
    var map = std.process.EnvMap.init(util.gpa);

    var mode: ScanMode = .key;
    var key_list = std.ArrayList(u8).init(util.gpa);
    defer key_list.deinit();
    var value_list = std.ArrayList(u8).init(util.gpa);
    defer value_list.deinit();
    for (val) |char| {
        // some env variables start with = called pseudo environment variables
        if (char == '=' and key_list.items.len > 0) {
            mode = .value;
            continue;
        }
        if (char == 0) {
            if (key_list.items.len == 0 and value_list.items.len == 0) {
                break;
            } 
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
            continue;
        }
        if (mode == .value) {
            value_list.append(char)
                catch |err| return e.verbose_error(err, error.TaskFileFailedRead);
            continue;
        }
    }

    return map;
}

// FREE THIS
pub fn map_to_string(map: *std.process.EnvMap) Errors![:0]u8 {
    var string_list = std.ArrayList(u8).init(util.gpa);
    defer string_list.deinit();
    var itr = map.iterator();
    while (itr.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (key.len == 0) {
            return error.FailedToGetEnvs;
        }
        const string = std.fmt.allocPrint(util.gpa, "{s}={s}\x00", .{key, value})
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
        defer util.gpa.free(string);

        string_list.appendSlice(string)
            catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
    }
    string_list.append(0)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);

    const sval = util.gpa.dupeZ(u8, string_list.items)
        catch |err| return e.verbose_error(err, error.FailedToGetEnvs);
    return sval;
}

test "lib/windows/env.zig" {
    std.debug.print("\n--- lib/windows/env.zig ---\n", .{});
}

test "Parse env block contents" {
    std.debug.print("Parse env block contents\n", .{});
    const content = try std.fmt.allocPrint(util.gpa, "KEY=VAL\x00KEY2=VAL2\x00MULTASK_TASK_ID=15\x00KEY3=VAL3\x00", .{});
    defer util.gpa.free(content);
    const wcontent = try std.unicode.utf8ToUtf16LeAlloc(util.gpa, content);
    defer util.gpa.free(wcontent);

    const task_id = try find_task_id_from_wenv_block(wcontent);

    std.debug.print("TASK ID: {any}\n", .{task_id});
    try expect(task_id != null and task_id == 15);
}

test "Converting map to windows env block" {
    std.debug.print("Converting map to windows env block\n", .{});

    var map = std.process.EnvMap.init(util.gpa);
    defer map.deinit();
    try map.put("env1", "val1");
    try map.put("env2", "val2");

    const str = try map_to_string(&map);
    defer util.gpa.free(str);

    const valid = "env1=val1\x00env2=val2\x00\x00";
    const valid_backwards = "env2=val2\x00env1=val1\x00\x00";
    try expect(
        std.mem.eql(u8, str, valid) or
        std.mem.eql(u8, str, valid_backwards)
    );
}

test "Converting windows env block to map" {
    std.debug.print("Converting windows env block to map\n", .{});
    const env_block = "env2=val2\x00env1=val1\x00\x00";

    var map = try string_to_map(env_block);
    defer map.deinit();

    const val1 = map.get("env1");
    const val2 = map.get("env2");

    try expect(val1 != null and std.mem.eql(u8, val1.?, "val1"));
    try expect(val2 != null and std.mem.eql(u8, val2.?, "val2"));
}
