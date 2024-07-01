use sysinfo::Pid;

use super::{process_iterator_linux::{close_process_iterator, get_next_process, init_process_iterator}, types::{Process, ProcessFilter, ProcessGroup, ProcessIterator}};

pub unsafe fn find_process_by_pid(pid: Pid) -> i32 {
    if libc::kill(pid, 0) == 0 {
        pid;
    } else {
        -pid;
    }
}

pub fn find_process_by_name(process_name: &String) -> i32 {
    let pid = -1;

    let it: ProcessIterator;
    let proc: Process;
    let filter: ProcessFilter;
	filter.pid = 0;
	filter.include_children = 0;
    unsafe {
        init_process_iterator(&mut it, filter);
        while get_next_process(&mut it, &mut proc) != 1 {
            if proc.command == process_name && libc::kill(pid, libc::SIGCONT) == 0 {
                pid = proc.pid;
                break;
            }
        }
        if close_process_iterator(&mut it) != 0 {
            libc::exit(1);
        }
    }
    if pid >= 0 {
        pid
    }
    0
}

pub fn init_process_group(pgroup: &mut ProcessGroup, target_pid: i32, include_children: i32) {
    pgroup.proctable = String::new();
    pgroup.target_pid = target_pid;
    pgroup.include_children = include_children;
    pgroup.proclist = Vec::new();
    pgroup.last_update = 0;
    update_process_group(pgroup);
}

