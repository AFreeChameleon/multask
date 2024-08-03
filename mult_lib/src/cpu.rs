use std::{thread, time::Duration};

use libc;

use crate::{proc::{get_all_processes, linux_get_cpu_stats, linux_get_process_stats}, tree::{search_tree, TreeNode}};

static MILS_IN_SECOND: f32 = 1000.0;

pub fn split_limit_cpu(pid: i32, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let mut running = true;
    loop {
        let process_tree = get_all_processes(pid as usize);
        let sig = if running { libc::SIGSTOP } else { libc::SIGCONT };
        let timeout = if running { idle_time } else { running_time };
        search_tree(&process_tree, &|node: &TreeNode| {
            unsafe { libc::kill(node.pid as i32, sig) };
        });
        thread::sleep(Duration::from_millis(timeout as u64));
        running = !running;
    }
}

fn linux_get_cpu_usage(pid: usize, node: TreeNode, old_total_time: u32) -> u32 {
    let stats = linux_get_process_stats(pid);
    let cpu_stats = linux_get_cpu_stats();
    let utime: u32 = stats[13].clone().parse().unwrap();
    let total_time = linux_get_cpu_time_total(cpu_stats);
    let old_utime= node.utime;

    let cpu_usage = 100 * (utime - old_utime) / (total_time - old_total_time);
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

pub fn get_cpu_usage(pid: usize, node: TreeNode, old_total_time: u32) -> u32 {
    #[cfg(target_os = "linux")]
    return linux_get_cpu_usage(pid, node, old_total_time);
}
