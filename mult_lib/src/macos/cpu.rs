use std::mem;
use std::ptr;
use std::thread;
use std::time::Duration;

use crate::proc::PID;
use crate::tree::{TreeNode, search_tree};
use crate::unix::proc::unix_get_error_code;
use crate::unix::proc::MILS_IN_SECOND;
use crate::macos::proc::macos_get_all_processes;

use super::proc::macos_get_all_process_stats;

const TASK_BASIC_INFO: libc::task_flavor_t = 4;
const THREAD_INFO_MAX: u32 = 1024;
const TIME_INTERVAL: f32 = 1E+9;

fn calc_nanoseconds_per_mach_tick() -> u32 {
    let mut info: libc::mach_timebase_info_data_t = unsafe {
        mem::zeroed()
    };
    unsafe { libc::mach_timebase_info(&mut info) };
    return info.numer / info.denom;
}

fn mach_ticks_to_nanoseconds(time: u64) -> u64 {
    return time * calc_nanoseconds_per_mach_tick() as u64;
}

pub fn macos_get_cpu_usage(node: &TreeNode, total_existing_time_ns: u64) -> (f32, u64) {
    let all_stats_opt = macos_get_all_process_stats(node.pid);
    // USE THIS INSTEAD
    let total_existing_time_nss = mach_ticks_to_nanoseconds(node.utime) + mach_ticks_to_nanoseconds(node.stime);
    if all_stats_opt.is_none() {
        println!("fail1");
        return (0.0, total_existing_time_ns);
    }
    let all_stats = all_stats_opt.unwrap();

    let user_time_ns = mach_ticks_to_nanoseconds(all_stats.ptinfo.pti_total_user);
    let system_time_ns = mach_ticks_to_nanoseconds(all_stats.ptinfo.pti_total_system);
    let total_current_time_ns = user_time_ns + system_time_ns;

    if total_current_time_ns != 0 {
        println!("time: {} {}", total_current_time_ns, total_existing_time_ns.to_owned());
        let total_time_diff_ns = total_current_time_ns - total_existing_time_ns.to_owned();
        let usage = (total_time_diff_ns as f32 / TIME_INTERVAL) * 100.0;
        return (usage, total_current_time_ns);
    } else {
        println!("fail2");
        return (0.0, total_current_time_ns);
    }
}

//pub fn macos_get_cpu_usage(pid: PID, node: TreeNode, old_total_time: u32) -> f32 {
//    let stats = macos_get_all_process_stats(pid);
//    let utime: u64 = stats.unwrap().ptinfo.pti_total_user;
//    let stime: u64 = stats.unwrap().ptinfo.pti_total_system;
//    let old_proc_times = node.utime + node.stime;
//    let proc_times = utime + stime;
//    let total_time = linux_get_cpu_time_total(cpu_stats);
//    let cpu_usage = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) as f32 }
//        * 100.0
//        * ((proc_times - old_proc_times) as f32 / (total_time - old_total_time) as f32);
//    return cpu_usage;
//}

pub fn macos_split_limit_cpu(pid: PID, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let mut running = true;
    loop {
        let process_tree = macos_get_all_processes(pid);
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
