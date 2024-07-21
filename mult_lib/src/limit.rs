use std::{collections::HashMap, thread, time::Duration};

use libc;
use sysinfo::{Pid, System};

static MILS_IN_SECOND: f32 = 1000.0;

unsafe fn next(pid: i32, running: bool, idle_time: i32, running_time: i32, sys: &mut System) {
    sys.refresh_processes();
    if sys.process(Pid::from(pid as usize)).is_some() {
        let mut timeout: Option<i32> = None;
        let sig = if running { libc::SIGSTOP } else { libc::SIGCONT };
        if libc::kill(pid, sig) == 0 {
            timeout = if running { Some(idle_time) } else { Some(running_time) };
        }
        if timeout.is_some() {
            thread::sleep(Duration::from_millis(timeout.unwrap() as u64));
            next(pid, !running, idle_time, running_time, sys);
        }
    }
}

pub fn limit_cpu(pid: i32, limit: f32) {
    let mut sys = System::new_all();
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let running = true;
    unsafe { next(pid, running, idle_time as i32, running_time as i32, &mut sys); }
}

fn get_all_processes(sys: &System, pid: usize) -> Vec<usize> {
    let mut all_processes: Vec<usize> = Vec::new();
    if let Some(process) = sys.process(Pid::from(pid)) {
        all_processes.push(process.pid().into());
        if let Some(tasks) = process.tasks() {
            for task_pid in tasks {
                if let Some(task) = sys.process(*task_pid) {
                    all_processes.push(task.pid().into());
                }
            }
        }
    }
    return all_processes;
}

pub fn split_cpu_limit(pid: usize, limit: f32) {
    let sys = System::new_all();
    let mut limiting_processes: HashMap<i32, bool> = HashMap::new();
    loop {
        let processes = get_all_processes(&sys, pid);
        let split_limit = limit / processes.len() as f32;
        for process_pid in processes {
            let is_limiting = limiting_processes.get(&(process_pid as i32));
            if is_limiting.is_none() || !is_limiting.unwrap().to_owned() {
                thread::spawn(move || {
                    limit_cpu(process_pid as i32, split_limit);
                });
                limiting_processes.entry(process_pid as i32).or_insert(true);
            }
        }
        thread::sleep(Duration::from_secs(1));
    }
}

