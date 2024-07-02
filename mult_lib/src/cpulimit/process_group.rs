use std::time::{Duration, SystemTime, UNIX_EPOCH};

use libc::c_long;
use sysinfo::Pid;

use super::{process_iterator_linux::{close_process_iterator, get_next_process, init_process_iterator}, types::{Process, ProcessFilter, ProcessGroup, ProcessIterator, ALFA, MIN_DT, PIDHASH_SZ}};

fn pid_hashfn(x: i32) {
    return ((((x) >> 8) ^ (x)) & (PIDHASH_SZ - 1));
}

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

pub fn close_process_group(pgroup: &mut ProcessGroup) {
    pgroup.proctable = Vec::new();
    pgroup.proclist = Vec::new();
}

pub fn timediff(t1: Duration, t2: Duration) -> Duration {
    return t1 - t2;
}

pub fn update_process_group(pgroup: &mut ProcessGroup) {
    let mut it: ProcessIterator;
    let mut tmp_process: Process;
    let mut filter: ProcessFilter;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let dt = now - pgroup.last_update;
    filter.pid = pgroup.target_pid;
    filter.include_children = pgroup.include_children;
    unsafe { init_process_iterator(&mut it, filter) }
    pgroup.proclist = Vec::new();
    unsafe { while get_next_process(&mut it, &mut tmp_process).is_ok() {
        let hashkey = pid_hashfn(&tmp_process.pid);
        if pgroup.proctable.get(hashkey).is_none() {
            tmp_process.cpu_usage = -1;
            let newtable = vec![tmp_process.clone()];
            pgroup.proctable.insert(hashkey, Some(newtable));
            pgroup.proclist.push(tmp_process.clone());
        } else {
            if let Some(p) = pgroup.proctable.get(hashkey) {
                pgroup.proclist.push(p.clone());
                if dt < MIN_DT {
                    continue;
                }
                let sample = 1 * (tmp_process.cputime - p.cputime) / dt;
                if p.cpu_usage == -1 {
                    p.cpu_usage = sample;
                } else {
                    p.cpu_usage = (1 - ALFA) * p.cpu_usage + ALFA * sample;
                }
                p.cputime = tmp_process.cputime;
            } else {
                tmp_process.cpu_usage = -1;
                pgroup.proctable.insert(hashkey, Some(tmp_process.clone()));
                pgroup.proclist.push(tmp_process.clone());
            }
        }
    }}
    close_process_iterator(&mut it);
    if dt < MIN_DT {
        return;
    }
    pgroup.last_update = now;
}

