use std::{cmp, collections::HashMap, fs::File, io::Read, thread, time::{Duration, SystemTime, UNIX_EPOCH}};

use crate::error::{print_error, print_success, MultError};

use super::{process_group::{close_process_group, find_process_by_pid, init_process_group, remove_process, update_process_group}, types::{Process, ProcessGroup, ProcessIterator, MAX_PRIORITY, TIME_SLOT}};


pub fn quit(sid: i32, pgroup: &mut ProcessGroup) {
    for p in pgroup.proclist.clone() {
        unsafe { libc::kill(p.pid, libc::SIGCONT); }
    }
    close_process_group(pgroup);
}

pub fn increase_priority() {
    let mut priority = unsafe { libc::getpriority(libc::PRIO_PROCESS, 0) }.clone();
    while (
        unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, priority-1) } == 0 &&
        priority > MAX_PRIORITY
    ) {
        priority -= 1;
    }
}

pub fn get_pid_max() -> i32 {
    #[cfg(target_os = "linux")] {
        let mut contents = String::new();
        let mut pid_file = match File::open("/proc/sys/kernel/pid_max") {
            Ok(val) => val,
            Err(_) => return -1
        };
        pid_file.read_to_string(&mut contents);
        return contents.parse::<i32>().unwrap();
    }
    #[cfg(target_os = "macos")] {
       return 99998; 
    }
    #[cfg(target_os = "freebsd")] {
       return 99998; 
    }
}

fn timediff(t1: u64, t2: u64) -> u64 {
    return (t1 - t2) * 1000000;
}

pub fn limit_process(
    pid: i32,
    limit: f64,
    include_children: bool,
    pgroup: &mut ProcessGroup
) {
    let mut twork: u64;
    let mut tsleep: u64;

    increase_priority();

    init_process_group(pgroup, pid, include_children);

    let mut working_rate = -1.0;
    loop {
        update_process_group(pgroup);

        if pgroup.proclist.len() == 0 {
            break;
        }

        let mut pcpu: f64 = -1.0;

        for proc in pgroup.proclist.iter() {
            if proc.cpu_usage < 0.0 { continue };
            if pcpu < 0.0 { pcpu = 0.0; }
            pcpu += proc.cpu_usage;
        }

        if pcpu < 0.0 {
            working_rate = limit;
            twork = (TIME_SLOT as f64 * limit * 1000.0) as u64;
        } else {
            let min_val = working_rate / pcpu * limit;
            working_rate = min_val.min(1.0);
            twork = (TIME_SLOT as f64 * limit * 1000.0) as u64;
        }
        tsleep = TIME_SLOT as u64 * 1000 - twork;
        let mut new_pgroup = pgroup.clone();
        for (idx, proc) in pgroup.proclist.iter().enumerate() {
            if unsafe { libc::kill(proc.pid, libc::SIGCONT) } != 0 {
                new_pgroup.proclist.remove(idx);
                remove_process(&mut new_pgroup, proc.pid);
            } 
        }
        pgroup.proclist = new_pgroup.proclist;
        pgroup.proctable = new_pgroup.proctable;
        thread::sleep(Duration::from_micros(twork));

        if tsleep > 0 {
            new_pgroup = pgroup.clone();
            for (idx, proc) in pgroup.proclist.iter().enumerate() {
				if unsafe { libc::kill(proc.pid, libc::SIGSTOP) } != 0 {
					//process is dead, remove it from family
					//remove process from group
                    new_pgroup.proclist.remove(idx);
					remove_process(&mut new_pgroup, proc.pid);
				}
            }
            pgroup.proclist = new_pgroup.proclist;
            pgroup.proctable = new_pgroup.proctable;
            thread::sleep(Duration::from_micros(tsleep));
        }
    }
    close_process_group(pgroup);
}

pub fn set_cpu_limit(pid: i32, perclimit: i32) {
    let limit: f64 = perclimit as f64 / 100.0;
    let ret = unsafe { find_process_by_pid(pid) };
    if ret == 0 {
        print_error(MultError::CustomError, Some("No process found.".to_string()));
    } else if ret < 0 {
        print_error(MultError::CustomError, Some("Missing permissions.".to_string()));
    }
    if ret > 0 {
        let mut pgroup = ProcessGroup {
            proctable: HashMap::new(),
            proclist: Vec::new(),
            target_pid: 0,
            include_children: true,
            last_update: 0
        };
        limit_process(pid, limit, true, &mut pgroup);
    }
}

