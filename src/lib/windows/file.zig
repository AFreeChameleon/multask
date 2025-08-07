const util = @import("../util.zig");
const Pid = util.Pid;
const e = @import("../error.zig");
const Errors = e.Errors;
const WindowsProcess = @import("./process.zig").WindowsProcess;

pub const TaskReadProcess = struct {
    pid: Pid,
    starttime: u64,

    pub fn init(proc: *const WindowsProcess) TaskReadProcess {
        return TaskReadProcess {
            .pid = proc.pid,
            .starttime = proc.starttime
        };
    }
};
pub const ReadProcess = struct {
    task: TaskReadProcess,
    pid: Pid,
    starttime: u64,
    children: ?[]ReadProcess,

    pub fn init(proc: *const WindowsProcess, task_proc: TaskReadProcess, children: ?[]ReadProcess) ReadProcess {
        return ReadProcess {
            .pid = proc.pid,
            .starttime = proc.starttime,
            .task = task_proc,
            .children = children
        };
    }

    pub fn deinit(self: *ReadProcess) void {
        if (self.children != null) {
            util.gpa.free(self.children.?);
        }
    }

    pub fn clone(self: *const ReadProcess) Errors!ReadProcess {
        const task_proc = TaskReadProcess {
            .pid = self.task.pid,
            .starttime = self.task.starttime,
        };
        const proc = ReadProcess {
            .task = task_proc,
            .pid = self.pid,
            .starttime = self.starttime,
            .children = util.gpa.dupe(ReadProcess, self.children.?)
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses)
        };
        return proc;
    }
};
