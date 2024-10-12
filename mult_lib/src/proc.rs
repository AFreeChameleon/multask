extern crate core;
extern crate std;

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::u32;

#[cfg(target_family = "unix")]
use crate::unix::proc::unix_proc_exists;
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

pub type ForkFlagTuple = (i64, i32, bool);

pub fn get_proc_name(pid: PID) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")]
    {
        use crate::linux::proc::linux_get_proc_name;
        return linux_get_proc_name(pid);
    }
    #[cfg(target_os = "windows")]
    {
        use crate::windows::proc::win_get_proc_name;
        return win_get_proc_name(pid);
    }
    #[cfg(target_os = "freebsd")]
    {
        use crate::bsd::proc::bsd_get_proc_comm;
        return bsd_get_proc_comm(pid);
    }
    #[cfg(target_os = "macos")]
    {
        use crate::macos::proc::macos_get_process_stats;
        use crate::unix::proc::unix_convert_c_string;
        let stats = macos_get_process_stats(pid);
        if stats.is_none() {
            return Ok(String::new());
        }
        Ok(unix_convert_c_string(stats.unwrap().pbi_name.iter()))
    }
}

pub fn get_proc_comm(pid: PID) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")]
    {
        use crate::linux::proc::linux_get_proc_comm;
        return linux_get_proc_comm(pid);
    }
    #[cfg(target_os = "windows")]
    {
        use crate::windows::proc::win_get_proc_name;
        return win_get_proc_name(pid);
    }
    #[cfg(target_os = "freebsd")]
    {
        use crate::bsd::proc::bsd_get_proc_comm;
        return bsd_get_proc_comm(pid);
    }
    #[cfg(target_os = "macos")]
    {
        use crate::macos::proc::macos_get_process_stats;
        use crate::unix::proc::unix_convert_c_string;
        let stats = macos_get_process_stats(pid);
        if stats.is_none() {
            return Ok(String::new());
        }

        Ok(unix_convert_c_string(stats.unwrap().pbi_comm.iter()))
    }
}

pub fn save_task_processes(path: &Path, tree: &TreeNode) {
    let encoded_data = bincode::serialize::<TreeNode>(tree).unwrap();
    fs::write(path.join("processes.bin"), encoded_data).unwrap();
}

pub fn save_usage_stats(path: &Path, stats: &HashMap<PID, UsageStats>) {
    let encoded_data = bincode::serialize::<HashMap<PID, UsageStats>>(stats).unwrap();
    fs::write(path.join("r_usage.bin"), encoded_data).unwrap();
}

pub fn read_usage_stats(task_id: u32) -> Result<HashMap<PID, UsageStats>, MultErrorTuple> {
    let process_dir = Path::new(&home::home_dir().unwrap())
        .join(".multi-tasker")
        .join("processes")
        .join(task_id.to_string());
    let usage_file = process_dir.join("r_usage.bin");
    if usage_file.exists() {
        let encoded: Vec<u8> = fs::read(usage_file).unwrap();
        let decoded: HashMap<PID, UsageStats> = match bincode::deserialize(&encoded[..]) {
            Ok(val) => val,
            Err(_) => return Err((MultError::TaskBinFileUnreadable, None)),
        };
        return Ok(decoded);
    }
    Ok(HashMap::new())
}

pub fn proc_exists(pid: PID) -> bool {
    #[cfg(target_family = "unix")]
    return unix_proc_exists(pid);
    #[cfg(target_os = "windows")]
    {
        use crate::windows::proc::win_proc_exists;
        return win_proc_exists(pid);
    }
}

pub fn get_readable_runtime(secs: u64) -> String {
    let seconds = secs % 60;
    let minutes = (secs / 60) % 60;
    let hours = (secs / 60) / 60;
    format!("{}h {}m {}s", hours, minutes, seconds).to_string()
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

pub fn convert_vec_to_array<T, const N: usize>(v: Vec<T>) -> [T; N] {
    return v.try_into().unwrap_or_else(|_v: Vec<T>| panic!());
}
