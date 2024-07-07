use std::{borrow::BorrowMut, collections::HashMap, hash::Hash, mem, time::{Duration, SystemTime, UNIX_EPOCH}};

use libc::exit;

use super::{process_iterator_linux::{close_process_iterator, get_next_process, init_process_iterator}, types::{Process, ProcessFilter, ProcessGroup, ProcessIterator, ALFA, MIN_DT, PIDHASH_SZ}};

fn pid_hashfn(x: i32) -> i32{
    return (((x) >> 8) ^ (x)) & (PIDHASH_SZ - 1);
}

pub unsafe fn find_process_by_pid(pid: i32) -> i32 {
    if libc::kill(pid, 0) == 0 {
        return pid;
    } else {
        return -pid;
    }
}

pub fn find_process_by_name(process_name: &String) -> i32 {
    let mut pid = -1;

    let mut it: ProcessIterator = unsafe { mem::zeroed() };
    let mut proc: Process = unsafe { mem::zeroed() };
    let mut filter: ProcessFilter = unsafe { mem::zeroed() };
	filter.pid = 0;
	filter.include_children = false;
    unsafe {
        init_process_iterator(&mut it, filter);
        while get_next_process(&mut it, &mut proc).is_ok() {
            if &proc.command == process_name && libc::kill(pid, libc::SIGCONT) == 0 {
                pid = proc.pid;
                break;
            }
        }
        if close_process_iterator(&mut it).is_err() {
            exit(1);
        }
    }
    if pid >= 0 {
        return pid;
    }
    return 0
}

pub fn init_process_group(pgroup: &mut ProcessGroup, target_pid: i32, include_children: bool) {
    pgroup.proctable = HashMap::new();
    pgroup.target_pid = target_pid;
    pgroup.include_children = include_children;
    pgroup.proclist = Vec::new();
    pgroup.last_update = 0;
    update_process_group(pgroup);
}

pub fn close_process_group(pgroup: &mut ProcessGroup) {
    pgroup.proctable = HashMap::new();
    pgroup.proclist = Vec::new();
}

pub fn timediff(t1: Duration, t2: Duration) -> Duration {
    return t1 - t2;
}

pub fn update_process_group(pgroup: &mut ProcessGroup) -> Result<i32, i32> {
    let mut it: ProcessIterator = unsafe { mem::zeroed() };
    let mut tmp_process: Process = unsafe { mem::zeroed() };
    let mut filter: ProcessFilter = unsafe { mem::zeroed() };
    let now = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(val) => val.as_secs(),
        Err(_) => return Err(-1)
    };
    let dt = now - pgroup.last_update;
    filter.pid = pgroup.target_pid;
    filter.include_children = pgroup.include_children;
    unsafe { init_process_iterator(&mut it, filter) };
    pgroup.proclist = Vec::new();
    unsafe { while get_next_process(&mut it, &mut tmp_process).is_ok() {
        let hashkey = pid_hashfn(tmp_process.pid);
        if pgroup.proctable.get(&hashkey).is_none() {
            tmp_process.cpu_usage = -1.0;
            let newtable = vec![tmp_process.clone()];
            pgroup.proctable.insert(hashkey, newtable);
            pgroup.proclist.push(tmp_process.clone());
        } else {
            if let Some(p_list) = pgroup.proctable.get(&hashkey).clone() {
                let p_idx = p_list
                    .into_iter()
                    .position(|p| p.pid == tmp_process.pid).unwrap();
                let mut p = p_list[p_idx].clone();
                pgroup.proclist.push(p.clone());
                if dt < MIN_DT {
                    continue;
                }
                let sample = 1.0 * (tmp_process.cputime as f64 - p.cputime as f64) / dt as f64;
                if p.cpu_usage == -1.0 {
                    p.cpu_usage = sample as f64;
                } else {
                    p.cpu_usage = (1.0 - ALFA) * p.cpu_usage + ALFA * sample;
                }
                p.cputime = tmp_process.cputime;
                pgroup.proctable.entry(hashkey).and_modify(|p_vec| p_vec[p_idx] = p);
            } else {
                tmp_process.cpu_usage = -1.0;
                pgroup.proctable.insert(hashkey, vec![tmp_process.clone()]);
                pgroup.proclist.push(tmp_process.clone());
            }
        }
    }}
    close_process_iterator(&mut it);
    if dt < MIN_DT {
        return Ok(0);
    }
    pgroup.last_update = now;
    Ok(0)
}

pub fn remove_process(pgroup: &mut ProcessGroup, pid: i32) -> Result<i32, i32> {
    let hashkey = pid_hashfn(pid);
    let proctable = pgroup.proctable.get(&pid);
    if proctable.is_none() {
        // nothing to delete
        return Ok(1);
    }
    let new_proctable: Vec<Process> = proctable.unwrap().iter()
        .filter(|p| p.pid != pid).cloned().collect();
    pgroup.proctable
        .entry(hashkey)
        .and_modify(|table| *table = new_proctable);
    Ok(0)
}

