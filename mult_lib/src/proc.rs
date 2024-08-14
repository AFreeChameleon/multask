extern crate core;
extern crate std;

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use sysinfo::{Pid, System};

use crate::tree::compress_tree;
use crate::{error::{MultError, MultErrorTuple}, tree::TreeNode};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UsageStats {
    pub cpu_usage: f32
}

fn linux_get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
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

pub fn get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")]
    let proc_name = linux_get_proc_name(pid)?;
    Ok(proc_name)
}

pub fn get_proc_comm(pid: u32) -> Result<String, MultErrorTuple> {
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

pub fn kill_all_processes(ppid: u32) -> Result<(), MultErrorTuple> {
    let sys = System::new_all();
    let process_tree = get_all_processes(ppid as usize);
    let mut all_processes = vec![];
    compress_tree(&process_tree, &mut all_processes);
    if let Some(process) = sys.process(Pid::from_u32(ppid)) {
        if let Some(parent_pid) = process.parent() {
            sys.process(parent_pid).unwrap().kill();
        }
    }
    for pid in all_processes {
        if let Some(process) = sys.process(Pid::from_u32(pid as u32)) {
            process.kill();
        } else {
            return Err((MultError::ProcessNotRunning, None))
        }
    }
    Ok(())
}

pub fn save_task_processes(path: &Path, tree: &TreeNode) {
    let encoded_data = bincode::serialize::<TreeNode>(tree).unwrap();
    fs::write(path.join("processes.bin"), encoded_data).unwrap();
}

pub fn save_usage_stats(path: &Path, stats: &HashMap<usize, UsageStats>) {
    let encoded_data = bincode::serialize::<HashMap<usize, UsageStats>>(stats).unwrap();
    fs::write(path.join("r_usage.bin"), encoded_data).unwrap();
}

pub fn read_usage_stats(task_id: u32) -> Result<HashMap<usize, UsageStats>, MultErrorTuple> {
    let process_dir = Path::new(&home::home_dir().unwrap())
        .join(".multi-tasker")
        .join("processes")
        .join(task_id.to_string());
    let usage_file = process_dir.join("r_usage.bin");
    if usage_file.exists() {
        let encoded: Vec<u8> = fs::read(usage_file).unwrap(); 
        let decoded: HashMap<usize, UsageStats> = match bincode::deserialize(&encoded[..]) {
            Ok(val) => val,
            Err(_) => return Err((MultError::TaskBinFileUnreadable, None))
        };
        return Ok(decoded);
    }
    Ok(HashMap::new())
}

pub fn proc_exists(pid: i32) -> bool {
    #[cfg(target_family = "unix")]
    return unsafe { libc::kill(pid, 0) } == 0;
}

pub fn get_all_processes(pid: usize) -> TreeNode {
    #[cfg(target_os = "linux")]
    return linux_get_all_processes(pid);
}

// uses proc api
fn linux_get_all_processes(pid: usize) -> TreeNode {
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
                let process_stats = linux_get_process_stats(usize_c_pid);
                let mut new_node = TreeNode {
                    pid: usize_c_pid,
                    utime: process_stats[13].parse().unwrap(),
                    stime: process_stats[14].parse().unwrap(),
                    children: Vec::new()
                };
                linux_get_process(usize_c_pid, &mut new_node);
                tree_node.children.push(new_node);            
            }
        }
    }
}

pub fn get_process_runtime(starttime: u32) -> f64 {
    #[cfg(target_os = "linux")]
    let runtime = linux_get_process_runtime(starttime);
    runtime
}

pub fn get_readable_runtime(secs: u64) -> String {
    let seconds = secs % 60;
    let minutes = (secs / 60) % 60;
    let hours = (secs / 60) / 60;
    format!("{}h {}m {}s", hours, minutes, seconds).to_string()
}

pub fn linux_get_process_runtime(starttime: u32) -> f64 {
    let secs_since_boot: f64 = fs::read_to_string("/proc/uptime")
        .unwrap().split_whitespace().nth(0).unwrap().parse().unwrap();
    let ticks_per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs() as f64;
    let run_time = since_epoch - (secs_since_boot - (starttime as f64 / ticks_per_sec as f64));
    since_epoch - run_time
}

pub fn linux_get_process_starttime(pid: usize) -> f64 {
    let stats = get_process_stats(pid);
    let secs_since_boot: f64 = fs::read_to_string("/proc/uptime")
        .unwrap().split_whitespace().nth(0).unwrap().parse().unwrap();
    let starttime: f64 = stats[23].clone().parse().unwrap();
    let ticks_per_sec = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs() as f64;
    since_epoch - (since_epoch - ((secs_since_boot - (starttime / ticks_per_sec as f64)) as f64))
}

pub fn get_process_starttime(pid: usize) -> f64 {
    #[cfg(target_os = "linux")]
    let starttime = linux_get_process_starttime(pid);
    starttime
}

pub fn get_process_stats(pid: usize) -> Vec<String> {
    #[cfg(target_os = "linux")]
    let stats = linux_get_process_stats(pid);
    stats
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
                stats.push(
                    if value.is_empty() {
                        stat.to_owned()
                    } else {
                        value.to_owned()
                    }
                );
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

pub fn get_process_memory(pid: &usize) -> String {
    #[cfg(target_os = "linux")]
    return linux_get_process_memory(pid);
}

pub fn linux_get_process_memory(pid: &usize) -> String {
    let mem_path = Path::new("/proc").join(pid.to_string()).join("status");
    if mem_path.exists() {
        let contents = fs::read_to_string(mem_path).unwrap();
        if let Some(vmrss) = contents.lines().find(|line| {
            line.starts_with("VmRSS")
        }) {
            let mut vmrss_line = vmrss.split_whitespace();
            return format!("{} {}", vmrss_line.nth(1).unwrap(), vmrss_line.next().unwrap());
        }
    }
    return "0 b".to_string();
}

