#![cfg(target_os = "freebsd")]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{ffi::CString, ptr};
use crate::bsd::cpu::bsd_get_cpu_usage;
use crate::error::MultErrorTuple;
use crate::proc::{get_readable_memory, save_task_processes, save_usage_stats, UsageStats, PID};
use crate::task::Files;
use crate::proc::ForkFlagTuple;
use crate::tree::{compress_tree, search_tree, TreeNode};
use crate::unix::proc::unix_kill_process;

pub fn bsd_get_process_stats(pid: PID) -> Option<libc::kinfo_proc> {
    let mut errbuf: [i8; 1024] = [0; 1024];
    let dev_null = CString::new("/dev/null").unwrap();
    let kd = unsafe {
        libc::kvm_openfiles(
            ptr::null(),
            dev_null.as_ptr() as *const i8,
            ptr::null(),
            libc::O_RDONLY,
            &mut errbuf as *mut i8,
        )
    };
    if kd.is_null() {
        return None;
    }
    let mut num_procs = -1;
    let procs = unsafe { libc::kvm_getprocs(kd, libc::KERN_PROC_PID, pid, &mut num_procs) };
    if procs.is_null() || unsafe { (*procs).ki_stat == libc::SZOMB } {
        return None;
    }
    unsafe { Some(*procs) }
}

fn bsd_get_child_processes(ppid: PID) -> Option<Vec<libc::kinfo_proc>> {
    let mut errbuf: [i8; 1024] = [0; 1024];
    let dev_null = CString::new("/dev/null").unwrap();
    let kd = unsafe {
        libc::kvm_openfiles(
            ptr::null(),
            dev_null.as_ptr() as *const i8,
            ptr::null(),
            libc::O_RDONLY,
            &mut errbuf as *mut i8,
        )
    };
    if kd.is_null() {
        return None;
    }
    let mut num_procs: i32 = 0;
    let procs = unsafe { libc::kvm_getprocs(kd, libc::KERN_PROC_PROC, 0, &mut num_procs) };
    if procs.is_null() || num_procs < 0 {
        return None;
    }
    let mut child_procs: Vec<libc::kinfo_proc> = Vec::new();
    for i in 0..num_procs {
        let proc = unsafe { *procs.wrapping_add(i as usize) };
        if proc.ki_ppid == ppid {
            child_procs.push(proc);
        }
    }

    Some(child_procs)
}

pub fn bsd_get_process_memory(stats: libc::kinfo_proc) -> String {
    let page_size = unsafe {
        libc::sysconf(libc::_SC_PAGE_SIZE)
    };
    get_readable_memory((stats.ki_rssize * page_size as isize) as f64)
}

pub fn bsd_get_all_processes(pid: PID) -> TreeNode {
    let mut head_node = TreeNode {
        pid,
        utime: 0,
        stime: 0,
        children: Vec::new(),
    };
    bsd_get_process(&mut head_node);
    head_node
}

fn bsd_get_process(tree_node: &mut TreeNode) {
    let child_procs_opt = bsd_get_child_processes(tree_node.pid);
    if child_procs_opt.is_none() {
        return;
    }
    let child_procs = child_procs_opt.unwrap();
    for c_proc in child_procs {
        let mut new_node = TreeNode {
            pid: c_proc.ki_pid as PID,
            utime: 0,
            stime: 0,
            children: Vec::new(),
        };
        bsd_get_process(&mut new_node);
        tree_node.children.push(new_node);
    }
}

pub fn bsd_proc_exists(pid: PID) -> bool {
    let stats = bsd_get_process_stats(pid);
    if stats.is_none() {
        return false;
    }
    return true;
}

pub fn bsd_get_proc_comm(pid: PID) -> Result<String, MultErrorTuple> {
    let stats = bsd_get_process_stats(pid);
    if stats.is_none() {
        return Ok(String::new());
    }
    Ok(String::from_utf8(stats.unwrap().ki_comm.iter().map(|&c| c as u8).collect()).unwrap())
}

pub fn bsd_get_runtime(starttime: u64) -> u64 {
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs();
    since_epoch - starttime
}

pub fn bsd_kill_all_processes(pid: PID) -> Result<(), MultErrorTuple> {
    let mut processes: Vec<PID> = Vec::new();
    compress_tree(&bsd_get_all_processes(pid), &mut processes);
    for child_pid in processes {
        unix_kill_process(child_pid as PID)?;
    }
    Ok(())
}

pub fn bsd_monitor_stats(pid: PID, files: Files, stats: ForkFlagTuple) {
    let (memory_limit, _, _) = stats;
    loop {
        // Get usage metrics
        let process_tree = bsd_get_all_processes(pid);
        save_task_processes(&files.process_dir, &process_tree);

        // Sleep for measuring usage over time
        thread::sleep(Duration::from_secs(1));

        // Check for any alive processes
        let usage_stats = Arc::new(Mutex::new(HashMap::new()));
        let keep_running = Arc::new(Mutex::new(false));
        search_tree(&process_tree, &|node: &TreeNode| {
            if bsd_proc_exists(node.pid) {
                if let Some(stats) = bsd_get_process_stats(node.pid) {
                    let page_size = unsafe {
                        libc::sysconf(libc::_SC_PAGE_SIZE)
                    };
                    let memory_usage = stats.ki_rssize * page_size as isize;
                    *keep_running.lock().unwrap() = !(
                        memory_limit != -1 && memory_usage as i64 > memory_limit
                    );
                    // Set cpu usage down here
                    let cpu_usage = bsd_get_cpu_usage(stats);
                    usage_stats
                        .lock()
                        .unwrap()
                        .insert(node.pid, UsageStats { cpu_usage });
                } else {
                    *keep_running.lock().unwrap() = false;
                }
            }
        });
        if !*keep_running.lock().unwrap() {
            break;
        }
        save_usage_stats(&files.process_dir, &usage_stats.lock().unwrap());
    }
}

pub fn bsd_get_proc_name(proc_stats_opt: Option<libc::kinfo_proc>) -> String {
    if let Some(proc_stats) = proc_stats_opt {
        return String::from_utf8(
            proc_stats
                .ki_comm
                .iter()
                .map(|&c| c as u8)
                .collect(),
        )
        .unwrap();
    }
    return String::new();
}
