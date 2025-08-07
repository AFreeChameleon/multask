const std = @import("std");
const log = @import("./log.zig");
const util = @import("./util.zig");

pub const Errors = error {
    ForkFailed,
    StdHandleCloseFailed,
    SetSidFailed,
    MissingCwd,
    CommandFailed,
    InternalLoggingFailed,
    MainDirNotFound,
    MainDirFailedCreate,
    PathNotFound,
    TasksFileMissingOrCorrupt,
    TasksDirNotFound,
    TasksDirFailedCreate,
    TasksIdsFileFailedCreate,
    TasksIdsFileFailedRead,
    TasksIdsFileFailedWrite,
    TasksIdsFileNotExists,
    TasksNamespacesFileNotExists,
    TaskFileFailedWrite,
    MissingHomeDirectory,
    TaskFileFailedCreate,
    TaskNotExists,
    TaskNotRunning,
    TaskAlreadyRunning,
    NoArgs,
    ParsingCommandArgsFailed,
    InvalidOption,
    MissingArgument,
    CorruptedTask,
    TaskLogsFailedToRead,
    FailedToSetWindowCols,
    TasksNamespacesFileFailedRead,
    TasksNamespacesFileFailedCreate,
    TasksNamespacesFileFailedDelete,
    NamespaceNotExists,

    FailedToGetProcessStats,
    FailedToGetProcessState,
    FailedToGetProcesses,
    FailedToGetProcessChildren,
    FailedToGetProcess,
    FailedToGetCpuStats,
    FailedToSaveProcesses,
    FailedToReadTaskPid,
    CommandTooLarge,

    FailedToSaveStats,
    FailedToGetTaskStats,
    FailedAppendTableRow,
    FailedToGetProcessMemory,
    FailedToGetProcessRuntime,
    FailedToGetCpuUsage,
    FailedToGetProcessComm,
    FailedToGetProcessName,
    FailedToGetProcessStarttime,
    FailedToDeleteTask,

    FailedToSetProcessStatus,

    ProcessNotExists,

    FailedToPrintTable,
    FailedToKillAllProcesses,
    FailedToKillProcess,

    ProcessFileFailedCreate,

    CpuLimitValueInvalid,
    CpuLimitValueMissing,
    MemoryLimitValueMissing,
    MemoryLimitValueInvalid,
    NamespaceValueMissing,
    NamespaceValueInvalid,

    FailedSetProcessFileCache,
    FailedSetTaskCache,

    InvalidShell,
    UnkownItemInTaskDir,
    UnkownItemInTasksDir,
    NamespaceValueCantBeAll,
    FailedToEditNamespace,
    SpawnExeNotFound,
    FileFailedValidation,
    FailedToCloseFiles,
    InvalidFile,
    InternalUtilError
};

pub fn verbose_error(og_err: anytype, mult_err: Errors) Errors {
    if (log.debug) {
        log.printdebug("Error: {any}", .{og_err})
            catch |err| std.debug.print("Error printing debug {any}\n", .{err});
    }
    return mult_err;
}

pub fn get_error_msg(e_type: Errors) Errors![]const u8 {
    var result: []const u8 = undefined;
    switch (e_type) {
        error.InternalUtilError => {
            result = "Internal utility function failed.";
        },
        error.InvalidFile => {
            result = "Invalid file.";
        },
        error.FailedToCloseFiles => {
            result = "File failed validation.";
        },
        error.FileFailedValidation => {
            result = "File failed validation.";
        },
        error.SpawnExeNotFound => {
            result = "Mult spawn executable not found.";
        },
        error.FailedToEditNamespace => {
            result = "Failed to edit namespace.";
        },
        error.UnkownItemInTaskDir => {
            result = "Unknown file/directory in task directory.";
        },
        error.UnkownItemInTasksDir => {
            result = "Unknown file/directory in tasks directory.";
        },
        error.InvalidShell => {
            result = "Shell is not recognised. Supported shells are zsh and bash at the moment.";
        },
        error.FailedSetProcessFileCache => {
            result = "Failed to set process file cache.";
        },
        error.FailedSetTaskCache => {
            result = "Failed to set task file cache.";
        },
        error.ProcessFileFailedCreate => {
            result = "Failed to create processes file.";
        },
        error.FailedToKillProcess => {
            result = "Failed to kill process.";
        },
        error.FailedToKillAllProcesses => {
            result = "Failed to kill all processes.";
        },
        error.FailedToPrintTable => {
            result = "Failed to print table.";
        },
        error.ProcessNotExists => {
            result = "Process does not exist.";
        },
        error.FailedToSetProcessStatus => {
            result = "Failed to set process status.";
        },
        error.FailedToDeleteTask => {
            result = "Failed to delete task.";
        },
        error.FailedToGetProcessStarttime => {
            result = "Failed to get process start time.";
        },
        error.FailedToGetProcessName => {
            result = "Failed to get process name.";
        },
        error.FailedToGetProcessComm => {
            result = "Failed to get process executable.";
        },
        error.FailedToGetCpuUsage => {
            result = "Failed to get process cpu usage.";
        },
        error.FailedToGetProcessRuntime => {
            result = "Failed to get process runtime.";
        },
        error.FailedToGetProcessMemory => {
            result = "Failed to get process memory.";
        },
        error.FailedAppendTableRow => {
            result = "Failed to add table row.";
        },
        error.FailedToGetTaskStats => {
            result = "Failed to get task stats.";
        },
        error.FailedToSaveStats => {
            result = "Failed to save task stats.";
        },
        error.CommandTooLarge => {
            result = "Command is too large.";
        },
        error.FailedToReadTaskPid => {
            result = "Failed to read task's pid.";
        },
        error.FailedToSaveProcesses => {
            result = "Failed to save processes.";
        },
        error.FailedToGetCpuStats => {
            result = "Failed to get CPU stats.";
        },
        error.FailedToGetProcess => {
            result = "Failed to find process.";
        },
        error.FailedToGetProcessChildren => {
            result = "Failed to get process children.";
        },
        error.FailedToGetProcesses => {
            result = "Failed to get processes.";
        },
        error.FailedToGetProcessState => {
            result = "Failed to get state of process.";
        },
        error.FailedToGetProcessStats => {
            result = "Failed to get stats of process.";
        },
        error.FailedToSetWindowCols => {
            result = "Failed to find size of window.";
        },
        error.TaskLogsFailedToRead => {
            result = "Failed to read task's logs.";
        },
        error.TasksDirNotFound => {
            result = "Tasks directory not found.";
        },
        error.PathNotFound => {
            result = "Could not find specified path.";
        },
        error.ForkFailed => {
            result = "Failed to create a subshell. Maybe this is a terminal I don't recognise?";
        },
        error.StdHandleCloseFailed => {
            result = "Failed to close stdout/err handles.";
        },
        error.SetSidFailed => {
            result = "Failed to set the sid of the subshell.";
        },
        error.MissingCwd => {
            result = "Missing current working working directory.";
        },
        error.CommandFailed => {
            result = "Command failed to execute.";
        },
        error.MainDirNotFound => {
            result = "Main directory doesn't exist.";
        },
        error.TasksFileMissingOrCorrupt => {
            result = "Tasks file is missing or corrupt.";
        },
        error.TasksIdsFileFailedCreate => {
            result = "Failed to create task ids file.";
        },
        error.TasksIdsFileFailedRead => {
            result = "Failed to read task ids file.";
        },
        error.TasksIdsFileFailedWrite => {
            result = "Failed to write to task ids file.";
        },
        error.TasksIdsFileNotExists => {
            result = "Task ids file does not exist.";
        },
        error.TasksNamespacesFileNotExists => {
            result = "Task namespaces file does not exist.";
        },
        error.TasksNamespacesFileFailedCreate => {
            result = "Failed to create task namespaces file.";
        },
        error.TasksNamespacesFileFailedRead => {
            result = "Failed to read task namespaces file.";
        },
        error.TasksNamespacesFileFailedDelete => {
            result = "Failed to delete task namespaces file.";
        },
        error.TaskFileFailedWrite => {
            result = "Task output failed to write.";
        },
        error.MissingHomeDirectory => {
            result = "Missing home directory.";
        },
        error.MainDirFailedCreate => {
            result = "Main directory failed to create.";
        },
        error.TaskFileFailedCreate => {
            result = "Task file failed to create.";
        },
        error.TasksDirFailedCreate => {
            result = "Tasks directory failed to create.";
        },
        error.ParsingCommandArgsFailed => {
            result = "Command failed to parse arguments.";
        },
        error.NoArgs => {
            result = "No arguments passed in.";
        },
        error.TaskNotExists => {
            result = "Task does not exist.";
        },
        error.NamespaceNotExists => {
            result = "Namespace does not exist.";
        },
        error.TaskAlreadyRunning => {
            result = "Task is already running.";
        },
        error.TaskNotRunning => {
            result = "Task is not running.";
        },
        error.InvalidOption => {
            result = "One or more options are invalid. Run mlt help for more info.";
        },
        error.MissingArgument => {
            result = "Missing option value. Run mlt help for more info.";
        },
        error.CorruptedTask => {
            result = "One or more tasks are corrupted. Run `mlt health` to troubleshoot";
        },
        error.CpuLimitValueInvalid => {
            result = "Cpu limit value invalid. Must be a number in between 1 and 99.";
        },
        error.CpuLimitValueMissing => {
            result = "Cpu limit needs to have a value.";
        },
        error.MemoryLimitValueInvalid => {
            result = "Memory must have be a valid number with a suffix e.g 10(b, k, m ...).";
        },
        error.MemoryLimitValueMissing => {
            result = "Memory limit needs to have a value.";
        },
        error.NamespaceValueMissing => {
            result = "Namespace flag needs to have a value.";
        },
        error.NamespaceValueInvalid => {
            result = "Namespace flag can only have letters in its value.";
        },
        error.NamespaceValueCantBeAll => {
            result = "Namespace name cannot be 'all'.";
        },
        else => {
            var buf: [util.Lengths.MEDIUM]u8 = undefined;
            result = std.fmt.bufPrint(&buf, "Unknown error occurred, code: {any}", .{e_type})
                catch return error.InternalLoggingFailed;
        }
    }
    return result;
}
