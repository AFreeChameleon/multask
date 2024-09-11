#![cfg(target_os = "linux")]
extern crate core;
extern crate std;

use std::fs::{self, File};
use std::io::Read;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use libc::{__errno_location, SIGINT};

use crate::proc::get_readable_memory;
use crate::tree::compress_tree;
use crate::{
    error::{MultError, MultErrorTuple},
    tree::TreeNode,
};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UsageStats {
    pub cpu_usage: f32,
}

pub fn linux_get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
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

pub fn linux_get_proc_comm(pid: u32) -> Result<String, MultErrorTuple> {
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

pub fn linux_proc_exists(pid: i32) -> bool {
    return unsafe { libc::kill(pid, 0) } == 0;
}

// uses proc api
pub fn linux_get_all_processes(pid: usize) -> TreeNode {
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

fn linux_get_process(pid: usize, tree_node: &mut TreeNode) {
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
                let usize_c_pid = c_pid.parse::<usize>().unwrap();
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

pub fn linux_get_process_runtime(starttime: u32) -> f64 {
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

pub fn linux_get_process_starttime(pid: usize) -> f64 {
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

pub fn linux_get_process_stats(pid: usize) -> Vec<String> {
    let initial_proc = format!("/proc/{}/stat", pid).to_owned();
    let stat_path = Path::new(&initial_proc);
    let mut stats: Vec<String> = Vec::new();
    if stat_path.exists() {
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

pub fn linux_get_process_memory(pid: &usize) -> String {
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

pub fn linux_kill_all_processes(pid: i32) -> Result<(), MultErrorTuple> {
    let mut processes: Vec<usize> = Vec::new();
    compress_tree(&linux_get_all_processes(pid as usize), &mut processes);
    for child_pid in processes {
        linux_kill_process(child_pid as i32)?;
    }
    Ok(())
}

pub fn linux_kill_process(pid: i32) -> Result<(), MultErrorTuple> {
    let res = unsafe { libc::kill(pid, SIGINT) };
    if res == 0 {
        return Ok(());
    }
    let errno = unsafe { *__errno_location() };
    Err((MultError::LinuxError, Some(errno.to_string())))
}
