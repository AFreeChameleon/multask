use std::{collections::HashMap, fs, path::Path, thread, time::Duration};

use libc;
use sysinfo::{Pid, System};

static MILS_IN_SECOND: f32 = 1000.0;

unsafe fn next(pid: i32, running: bool, idle_time: i32, running_time: i32, sys: &mut System) {
    //sys.refresh_processes();
    //if let Some(process) = sys.process(Pid::from(pid as usize)) {
        let mut timeout: Option<i32> = None;
        let sig = if running { libc::SIGSTOP } else { libc::SIGCONT };
        if libc::kill(pid, sig) == 0 {
            timeout = if running {
                //let limit = running_time / 10;
                //let cpu_usage = process.cpu_usage() as i32;
                Some(idle_time)
                //if cpu_usage > limit {
                //    Some(((cpu_usage - limit) * 10) / 1000)
                //} else { Some(0) }
            } else { Some(running_time) };
        }
        if timeout.is_some() {
            if timeout.unwrap() > 0 {
                thread::sleep(Duration::from_millis(timeout.unwrap() as u64));
            }
            next(pid, !running, idle_time, running_time, sys);
        }
    //}
}

pub fn limit_cpu(pid: i32, limit: f32) {
    let mut sys = System::new_all();
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let running = true;
    unsafe { next(
        pid,
        running,
        idle_time as i32,
        running_time as i32,
        &mut sys
    ); }
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

// uses proc api
pub fn linux_get_all_processes(pid: usize) -> Vec<usize> {
    let mut all_processes: Vec<usize> = vec![pid];
    linux_get_process(pid, &mut all_processes);
    return all_processes;
}

fn linux_get_process(pid: usize, all_processes: &mut Vec<usize>) {
    let initial_proc = format!("/proc/{}/", pid).to_owned();
    let proc_path = Path::new(&initial_proc);
    if proc_path.exists() {
        let child_path = proc_path.join("task").join(pid.to_string()).join("children");
        if child_path.exists() {
            let contents = fs::read_to_string(child_path).unwrap();
            let child_pids = contents.split_whitespace();
            for c_pid in child_pids {
                let usize_c_pid = c_pid.parse::<usize>().unwrap();
                all_processes.push(usize_c_pid);            
                linux_get_process(usize_c_pid, all_processes);
            }
        }
    }
}

pub fn split_cpu_limit(pid: usize, limit: f32) {
    let _sys = System::new_all();
    // DO CLEANUP OF OLD PROCESSES
    let mut limiting_processes: HashMap<i32, bool> = HashMap::new();
    let mut count = 0;
    loop {
        count += 1;
        let processes = linux_get_all_processes(pid);
        println!("{:?}", processes);
        let split_limit = (limit / (processes.len() - 1) as f32).floor();
        fs::write("/home/bean/logs.txt", format!("{} {}: {:?} {:?}", count, split_limit, processes, limiting_processes)).unwrap();
        for process_pid in processes {
            let is_limiting = limiting_processes.get(&(process_pid as i32));
            if is_limiting.is_none() {
                thread::spawn(move || {
                    limit_cpu(process_pid as i32, split_limit);
                });
                limiting_processes.entry(process_pid as i32).or_insert(true);
            } else if is_limiting.is_some() && !is_limiting.unwrap().to_owned() {
                thread::spawn(move || {
                    limit_cpu(process_pid as i32, split_limit);
                });
                limiting_processes.entry(process_pid as i32).or_insert(true);
            } else {
                limiting_processes.entry(process_pid as i32).or_insert(false);
            }
        }
        thread::sleep(Duration::from_secs(1));
    }
}

