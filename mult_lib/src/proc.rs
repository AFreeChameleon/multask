extern crate core;
extern crate std;

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use std::u32;

use sysinfo::{Pid, System};

#[cfg(target_family = "unix")]
use crate::linux::proc::{
    linux_get_proc_name, linux_get_process_memory, linux_get_process_runtime,
    linux_get_process_stats, linux_proc_exists,
};
use crate::tree::compress_tree;
use crate::{
    error::{MultError, MultErrorTuple},
    tree::TreeNode,
};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UsageStats {
    pub cpu_usage: f32,
}

pub fn get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")]
    Ok(linux_get_proc_name(pid)?);
    Ok(String::new())
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
            return Err((MultError::ProcessNotRunning, None));
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
            Err(_) => return Err((MultError::TaskBinFileUnreadable, None)),
        };
        return Ok(decoded);
    }
    Ok(HashMap::new())
}

pub fn proc_exists(pid: i32) -> bool {
    #[cfg(target_family = "unix")]
    return linux_proc_exists(pid);
    return false;
}

pub fn get_all_processes(pid: usize) -> TreeNode {
    #[cfg(target_os = "linux")]
    return linux_get_all_processes(pid);
    return TreeNode {
        pid: usize::MIN,
        utime: u32::MIN,
        stime: u32::MIN,
        children: Vec::new(),
    };
}

pub fn get_process_runtime(starttime: u32) -> f64 {
    #[cfg(target_os = "linux")]
    return linux_get_process_runtime(starttime);
    return 0.0;
}

pub fn get_readable_runtime(secs: u64) -> String {
    let seconds = secs % 60;
    let minutes = (secs / 60) % 60;
    let hours = (secs / 60) / 60;
    format!("{}h {}m {}s", hours, minutes, seconds).to_string()
}

pub fn get_process_starttime(pid: usize) -> f64 {
    #[cfg(target_os = "linux")]
    return linux_get_process_starttime(pid);
    return 0.0;
}

pub fn get_process_stats(pid: usize) -> Vec<String> {
    #[cfg(target_os = "linux")]
    return linux_get_process_stats(pid);
    return Vec::new();
}

pub fn get_process_memory(pid: &usize) -> String {
    #[cfg(target_os = "linux")]
    return linux_get_process_memory(pid);
    return String::new();
}
