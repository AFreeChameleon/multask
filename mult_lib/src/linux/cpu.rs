#![cfg(target_os = "linux")]
use std::{thread, time::Duration};

use libc;

use crate::proc::PID;
use crate::unix::proc::MILS_IN_SECOND;
use crate::{
    linux::proc::{linux_get_all_processes, linux_get_cpu_stats, linux_get_process_stats},
    tree::{search_tree, TreeNode},
};

pub fn linux_split_limit_cpu(pid: PID, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let mut running = true;
    loop {
        let process_tree = linux_get_all_processes(pid);
        let sig = if running {
            libc::SIGSTOP
        } else {
            libc::SIGCONT
        };
        let timeout = if running { idle_time } else { running_time };
        search_tree(&process_tree, &|node: &TreeNode| {
            unsafe { libc::kill(node.pid, sig) };
        });
        thread::sleep(Duration::from_millis(timeout as u64));
        running = !running;
    }
}

pub fn linux_get_cpu_usage(pid: PID, node: TreeNode, old_total_time: u32) -> f32 {
    let stats = linux_get_process_stats(pid);
    let cpu_stats = linux_get_cpu_stats();
    let utime: u64 = stats[13].clone().parse().unwrap();
    let stime: u64 = stats[14].clone().parse().unwrap();
    let old_proc_times = node.utime + node.stime;
    let proc_times = utime + stime;
    let total_time = linux_get_cpu_time_total(cpu_stats);
    let cpu_usage = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) as f32 }
        * 100.0
        * ((proc_times - old_proc_times) as f32 / (total_time - old_total_time) as f32);
    return cpu_usage;
}

pub fn linux_get_cpu_time_total(cpu_stats: Vec<String>) -> u32 {
    let mut time_total: u32 = 0;
    for str_time in cpu_stats {
        if let Ok(time) = str_time.parse::<u32>() {
            time_total += time;
        }
    }
    return time_total;
}
