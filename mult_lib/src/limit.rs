use std::{collections::HashMap, fs, path::Path, sync::{Arc, Mutex}, thread, time::Duration};

use libc;
use sysinfo::{Pid, System};

use crate::tree::{search_tree, TreeNode};

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

pub fn new_limit_cpu(pid: i32, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let mut running = true;
    loop {
        println!("New Loop Starting {}", running);
        let process_tree = get_all_processes(pid as usize);
        let sig = if running { libc::SIGSTOP } else { libc::SIGCONT };
        let timeout = if running { idle_time } else { running_time };
        search_tree(&process_tree, &|c_pid: usize| {
            if unsafe { libc::kill(c_pid as i32, sig) } != 0 {
                println!("Process Missing {} {}", c_pid, running);
            }
        });
        thread::sleep(Duration::from_millis(timeout as u64));
        running = !running;
    }
}

pub fn split_cpu_limit(pid: usize, limit: f32) {
    let _sys = System::new_all();
    // DO CLEANUP OF OLD PROCESSES
    let mut limiting_processes: HashMap<i32, bool> = HashMap::new();
    let mut count = 0;
    loop {
        count += 1;
        let process_tree = linux_get_all_processes(pid);
        let arc_process_list = Arc::new(Mutex::new(Vec::new()));
        search_tree(&process_tree, &|pid: usize| {
            arc_process_list.lock().unwrap().push(pid);
        });
        let process_list = arc_process_list.lock().unwrap().clone().into_iter();
        let split_limit = (limit / (process_list.len() - 1) as f32).floor();
        for process_pid in process_list {
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

//let mut all_processes: Vec<usize> = Vec::new();
//if let Some(process) = sys.process(Pid::from(pid)) {
//    all_processes.push(process.pid().into());
//    if let Some(tasks) = process.tasks() {
//        for task_pid in tasks {
//            if let Some(task) = sys.process(*task_pid) {
//                all_processes.push(task.pid().into());
//            }
//        }
//    }
//}
//return all_processes;
pub fn get_all_processes(pid: usize) -> TreeNode {
    #[cfg(target_os = "linux")]
    return linux_get_all_processes(pid);
}

// uses proc api
fn linux_get_all_processes(pid: usize) -> TreeNode {
    let mut head_node = TreeNode {
        pid,
        children: Vec::new()
    };
    linux_get_process(pid, &mut head_node);
    return head_node;
}

fn linux_get_process(pid: usize, tree_node: &mut TreeNode) {
    let initial_proc = format!("/proc/{}/", pid).to_owned();
    let proc_path = Path::new(&initial_proc);
    if proc_path.exists() {
        let child_path = proc_path.join("task").join(pid.to_string()).join("children");
        if child_path.exists() {
            let contents = fs::read_to_string(child_path).unwrap();
            let child_pids = contents.split_whitespace();
            for c_pid in child_pids {
                let usize_c_pid = c_pid.parse::<usize>().unwrap();
                let mut new_node = TreeNode {
                    pid: usize_c_pid,
                    children: Vec::new()
                };
                linux_get_process(usize_c_pid, &mut new_node);
                tree_node.children.push(new_node);            
            }
        }
    }
}
