const util = @import("../util.zig");
const Pid = util.Pid;
const Sid = util.Sid;
const Pgrp = util.Pgrp;
const e = @import("../error.zig");
const Errors = e.Errors;
const MacosProcess = @import("./process.zig").MacosProcess;

pub const TaskReadProcess = struct {
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
    
    pub fn init(proc: *const MacosProcess) TaskReadProcess {
        return TaskReadProcess {
            .pid = proc.pid,
            .sid = proc.sid,
            .pgrp = proc.pgrp,
            .starttime = proc.starttime,
        };
    }
};
pub const ReadProcess = struct {
    task: TaskReadProcess,
    pid: Pid,
    sid: Sid,
    pgrp: Pgrp,
    starttime: u64,
    children: ?[]ReadProcess,

    pub fn init(proc: *const MacosProcess, task_proc: TaskReadProcess, children: ?[]ReadProcess) ReadProcess {
        return ReadProcess {
            .pid = proc.pid,
            .sid = proc.sid,
            .pgrp = proc.pgrp,
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
            .sid = self.task.sid,
            .pgrp = self.task.pgrp,
            .starttime = self.task.starttime,
        };
        const proc = ReadProcess {
            .task = task_proc,
            .pid = self.pid,
            .sid = self.sid,
            .pgrp = self.pgrp,
            .starttime = self.starttime,
            .children = util.gpa.dupe(ReadProcess, self.children.?)
                catch |err| return e.verbose_error(err, error.FailedToSaveProcesses)
        };
        return proc;
    }
};
