#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::proc::{get_readable_memory, save_task_processes, save_usage_stats, UsageStats, PID};
use crate::task::Files;
use crate::tree::{compress_tree, search_tree};
use crate::unix::proc::{unix_kill_process, unix_proc_exists};
use crate::{
    error::{MultError, MultErrorTuple},
    tree::TreeNode,
};

use super::cpu::{linux_get_cpu_time_total, linux_get_cpu_usage};

pub fn linux_get_proc_name(pid: PID) -> Result<String, MultErrorTuple> {
    let mut proc_name = String::new();
    let mut proc_file = match File::open(format!("/proc/{}/cmdline", pid)) {
        Ok(val) => val,
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    match proc_file.read_to_string(&mut proc_name) {
        Ok(_) => (),
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    Ok(proc_name)
}

pub fn linux_get_proc_comm(pid: PID) -> Result<String, MultErrorTuple> {
    let mut proc_comm = String::new();
    let mut proc_file = match File::open(format!("/proc/{}/comm", pid)) {
        Ok(val) => val,
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    match proc_file.read_to_string(&mut proc_comm) {
        Ok(_) => (),
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    Ok(proc_comm.trim().to_string())
}

pub fn linux_proc_exists(pid: PID) -> bool {
    if let Some(state) = linux_get_process_state(pid) {
        if state == "Z" {
            return false;
        }
        return true;
    }
    return unsafe { libc::kill(pid, 0) } == 0;
}

// uses proc api
pub fn linux_get_all_processes(pid: PID) -> TreeNode {
    let process_stats = linux_get_process_stats(pid);
    let mut utime = 0;
    let mut stime = 0;
    if process_stats.len() > 0 {
        utime = process_stats[13].parse().unwrap();
        stime = process_stats[14].parse().unwrap();
    }
    let mut head_node = TreeNode {
        pid,
        utime,
        stime,
        children: Vec::new(),
    };
    linux_get_process(pid, &mut head_node);
    return head_node;
}

fn linux_get_process(pid: PID, tree_node: &mut TreeNode) {
    let initial_proc = format!("/proc/{}/", pid).to_owned();
    let proc_path = Path::new(&initial_proc);
    if proc_path.exists() {
        let child_path = proc_path
            .join("task")
            .join(pid.to_string())
            .join("children");
        if child_path.exists() {
            let contents = fs::read_to_string(child_path).unwrap();
            let child_pids = contents.split_whitespace();
            for c_pid in child_pids {
                let usize_c_pid = c_pid.parse::<PID>().unwrap();
                let process_stats = linux_get_process_stats(usize_c_pid);
                let mut new_node = TreeNode {
                    pid: usize_c_pid,
                    utime: process_stats[13].parse().unwrap(),
                    stime: process_stats[14].parse().unwrap(),
                    children: Vec::new(),
                };
                linux_get_process(usize_c_pid, &mut new_node);
                tree_node.children.push(new_node);
            }
        }
    }
}

pub fn linux_get_process_runtime(starttime: u64) -> f64 {
    let secs_since_boot: f64 = fs::read_to_string("/proc/uptime")
        .unwrap()
        .split_whitespace()
        .nth(0)
        .unwrap()
        .parse()
        .unwrap();
    let ticks_per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs() as f64;
    let run_time = since_epoch - (secs_since_boot - (starttime as f64 / ticks_per_sec as f64));
    since_epoch - run_time
}

pub fn linux_get_process_starttime(pid: PID) -> f64 {
    let stats = linux_get_process_stats(pid);
    let secs_since_boot: f64 = fs::read_to_string("/proc/uptime")
        .unwrap()
        .split_whitespace()
        .nth(0)
        .unwrap()
        .parse()
        .unwrap();
    let starttime: f64 = stats[23].clone().parse().unwrap();
    let ticks_per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs() as f64;
    since_epoch - (since_epoch - ((secs_since_boot - (starttime / ticks_per_sec as f64)) as f64))
}

pub fn linux_get_process_stats(pid: PID) -> Vec<String> {
    let initial_proc = format!("/proc/{}/stat", pid).to_owned();
    let stat_path = Path::new(&initial_proc);
    let mut stats: Vec<String> = Vec::new();
    if stat_path.exists() && linux_proc_exists(pid) {
        let contents = fs::read_to_string(stat_path).unwrap();
        let mut inside_brackets = false;
        let mut value = String::new();
        for stat in contents.split_whitespace() {
            if stat.chars().nth(0).unwrap() == '(' {
                inside_brackets = true;
                stat.to_string().remove(0);
                value.push_str(&stat);
            }
            if stat.chars().last().unwrap() == ')' {
                inside_brackets = false;
                stat.to_string().pop();
                value.push_str(&stat);
            }

            if !inside_brackets {
                stats.push(if value.is_empty() {
                    stat.to_owned()
                } else {
                    value.to_owned()
                });
                value = String::new();
            }
        }
    }
    return stats;
}

pub fn linux_get_cpu_stats() -> Vec<String> {
    let stat_path = Path::new("/proc/stat");
    let mut stats: Vec<String> = Vec::new();
    if stat_path.exists() {
        let contents = fs::read_to_string(stat_path).unwrap();
        let cpu_line = contents.lines().nth(0).unwrap();
        for val in cpu_line.split_whitespace() {
            stats.push(val.to_owned());
        }
    }
    return stats;
}

pub fn linux_get_process_memory(pid: &PID) -> String {
    let mem_path = Path::new("/proc").join(pid.to_string()).join("status");
    if mem_path.exists() {
        let contents = fs::read_to_string(mem_path).unwrap();
        if let Some(vmrss) = contents.lines().find(|line| line.starts_with("VmRSS")) {
            let mut vmrss_line = vmrss.split_whitespace();
            let memory: f64 = vmrss_line.nth(1).unwrap().parse().unwrap();
            return get_readable_memory(memory);
        }
    }
    return "0 B".to_string();
}

pub fn linux_get_process_state(pid: PID) -> Option<String> {
    let path = Path::new("/proc").join(pid.to_string()).join("status");
    if path.exists() {
        let contents = fs::read_to_string(&path).unwrap();
        if let Some(state) = contents.lines().find(|line| line.starts_with("State")) {
            let mut state_line = state.split_whitespace();
            let p_state = state_line.nth(1).unwrap();
            return Some(p_state.to_owned());
        }
    }
    return None;
}

pub fn linux_kill_all_processes(pid: PID) -> Result<(), MultErrorTuple> {
    let mut processes: Vec<PID> = Vec::new();
    compress_tree(&linux_get_all_processes(pid), &mut processes);
    for child_pid in processes {
        unix_kill_process(child_pid as PID)?;
    }
    Ok(())
}

pub fn linux_monitor_stats(pid: PID, files: Files) {
    let mut cpu_time_total;
    loop {
        // Get usage metrics
        let process_tree = linux_get_all_processes(pid);
        save_task_processes(&files.process_dir, &process_tree);
        cpu_time_total = linux_get_cpu_time_total(linux_get_cpu_stats());

        // Sleep for measuring usage over time
        thread::sleep(Duration::from_secs(1));

        // Check for any alive processes
        let usage_stats = Arc::new(Mutex::new(HashMap::new()));
        let keep_running = Arc::new(Mutex::new(false));
        search_tree(&process_tree, &|node: &TreeNode| {
            if unix_proc_exists(node.pid) {
                *keep_running.lock().unwrap() = true;
                // Set cpu usage down here
                usage_stats.lock().unwrap().insert(
                    node.pid,
                    UsageStats {
                        cpu_usage: linux_get_cpu_usage(node.pid, node.clone(), cpu_time_total),
                    },
                );
            }
        });
        if !*keep_running.lock().unwrap() {
            break;
        }
        save_usage_stats(&files.process_dir, &usage_stats.lock().unwrap());
    }
}
