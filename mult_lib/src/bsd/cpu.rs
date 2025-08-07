#![cfg(target_os = "freebsd")]

use crate::bsd::proc::bsd_get_all_processes;
use crate::proc::PID;
use crate::tree::{search_tree, TreeNode};
use crate::unix::proc::MILS_IN_SECOND;
use std::ffi::{c_void, CString};
use std::mem;
use std::ptr;
use std::thread;
use std::time::Duration;

pub fn bsd_get_cpu_usage(stats: libc::kinfo_proc) -> f32 {
    let mut kernel_f_scale: u32 = 0;
    let mut len = mem::size_of::<u32>();
    let param = CString::new("kern.fscale").unwrap();
    if unsafe {
        libc::sysctlbyname(
            param.as_ptr() as *const i8,
            &mut kernel_f_scale as *mut _ as *mut c_void,
            &mut len as *mut usize,
            ptr::null(),
            0,
        )
    } == -1
    {
        // htop says so
        kernel_f_scale = 2048;
    }
    100.0 * (stats.ki_pctcpu as f32 / kernel_f_scale as f32)
}

pub fn bsd_split_limit_cpu(pid: PID, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let mut running = true;
    loop {
        let process_tree = bsd_get_all_processes(pid);
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
