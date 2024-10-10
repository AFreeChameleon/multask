#![cfg(target_family = "windows")]
use std::mem;

use windows_sys::Win32::{
    Foundation::FILETIME,
    System::SystemInformation::{GetSystemInfo, GetSystemTimeAsFileTime, SYSTEM_INFO},
};

use crate::{proc::PID, tree::TreeNode};

use super::proc::{combine_filetime, win_get_process_stats};

pub fn win_get_processor_count() -> u32 {
    let mut system_info: SYSTEM_INFO = unsafe { mem::zeroed() };
    unsafe { GetSystemInfo(&mut system_info) };
    return system_info.dwNumberOfProcessors;
}

pub fn win_get_cpu_usage(pid: PID, last_time: u64, node: TreeNode) -> u64 {
    let processor_count = win_get_processor_count() as u64;
    let stats = win_get_process_stats(pid);
    if stats.len() == 0 {
        return 0;
    }
    let mut now: FILETIME = unsafe { mem::zeroed() };
    unsafe { GetSystemTimeAsFileTime(&mut now) };
    let system_time = stats[0].parse::<u64>().unwrap() + stats[1].parse::<u64>().unwrap();
    let last_system_time = node.utime + node.stime;
    let time = combine_filetime(&now);
    let system_time_delta = system_time - last_system_time;
    let time_delta = time - last_time;
    let usage = ((system_time_delta * 100 + time_delta / 2) / time_delta) / processor_count;
    return usage;
}
