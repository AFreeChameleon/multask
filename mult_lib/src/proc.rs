extern crate core;
extern crate std;

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::u32;

#[cfg(target_family = "unix")]
use crate::linux::proc::{
    linux_get_proc_comm, linux_get_proc_name, linux_get_process_memory,
    linux_get_process_stats, linux_proc_exists,
};
use crate::{
    error::{MultError, MultErrorTuple},
    tree::TreeNode,
};

// TODO - integrate this soon
#[cfg(target_family = "unix")]
pub type PID = i32;
#[cfg(target_os = "windows")]
pub type PID = u32;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UsageStats {
    pub cpu_usage: f32,
}

pub fn get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")]
    return linux_get_proc_name(pid);
    #[cfg(target_os = "windows")]
    return win_get_proc_name(pid);
}

pub fn get_proc_comm(pid: u32) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")]
    return linux_get_proc_comm(pid);
    #[cfg(target_os = "windows")]
    return win_get_proc_name(pid);
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
    #[cfg(target_os = "windows")]
    return win_proc_exists(pid as u32);
}

pub fn get_readable_runtime(secs: u64) -> String {
    let seconds = secs % 60;
    let minutes = (secs / 60) % 60;
    let hours = (secs / 60) / 60;
    format!("{}h {}m {}s", hours, minutes, seconds).to_string()
}

pub fn get_process_stats(pid: usize) -> Vec<String> {
    #[cfg(target_os = "linux")]
    return linux_get_process_stats(pid);
    #[cfg(target_os = "windows")]
    return win_get_process_stats(pid);
}

pub fn get_process_memory(pid: &usize) -> String {
    #[cfg(target_os = "linux")]
    return linux_get_process_memory(pid);
    #[cfg(target_family = "windows")] {
        use crate::windows::proc::win_get_process_stats;
        use crate::windows::proc::{
            win_get_memory_usage, win_get_proc_name, win_kill_process, win_proc_exists
        };
        return win_get_memory_usage(pid);
    }
}

// binary memory is 1024
// file memory is 1000
const SUFFIX: [&str; 9] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"];
const UNIT: f64 = 1024.0;
pub fn get_readable_memory(bytes: f64) -> String {
    if bytes <= 0.0 {
        return "0 B".to_string();
    }
    let base = bytes.log10() / UNIT.log10();
    let result = format!("{:.1}", UNIT.powf(base - base.floor()),)
    .trim_end_matches(".0")
    .to_owned();

    [&result, SUFFIX[base.floor() as usize]].join(" ")
}
