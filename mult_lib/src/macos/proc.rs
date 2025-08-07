#![cfg(target_os = "macos")]
use std::{
    collections::HashMap, ffi::c_void, mem, ptr, sync::{Arc, Mutex}, thread, time::{Duration, SystemTime, UNIX_EPOCH}
};

use crate::{
    error::MultErrorTuple,
    proc::{save_task_processes, save_usage_stats, ForkFlagTuple, UsageStats, PID},
    task::Files,
    tree::{compress_tree, search_tree, TreeNode},
    unix::proc::unix_kill_process,
};

use super::cpu::macos_get_cpu_usage;

const PID_LIST_MAX: usize = 1024;

pub fn macos_get_process_stats(pid: PID) -> Option<libc::proc_bsdinfo> {
    let mut info: libc::proc_bsdinfo = unsafe { mem::zeroed() };
    let res = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut c_void,
            mem::size_of::<libc::proc_bsdinfo>() as i32,
        )
    };
    if res != mem::size_of::<libc::proc_bsdinfo>() as i32 || info.pbi_status == libc::SZOMB {
        return None;
    }
    return Some(info);
}

pub fn macos_get_task_stats(pid: PID) -> Option<libc::proc_taskinfo> {
    let mut info: libc::proc_taskinfo = unsafe { mem::zeroed() };
    let res = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKINFO,
            0,
            &mut info as *mut _ as *mut c_void,
            mem::size_of::<libc::proc_taskinfo>() as i32,
        )
    };
    if res != mem::size_of::<libc::proc_taskinfo>() as i32 {
        return None;
    }
    return Some(info);
}

pub fn macos_get_all_process_stats(pid: PID) -> Option<libc::proc_taskallinfo> {
    let mut info: libc::proc_taskallinfo = unsafe { mem::zeroed() };
    let res = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKALLINFO,
            0,
            &mut info as *mut _ as *mut c_void,
            mem::size_of::<libc::proc_taskallinfo>() as i32,
        )
    };
    if res != mem::size_of::<libc::proc_taskallinfo>() as i32 || info.pbsd.pbi_status == libc::SZOMB
    {
        return None;
    }
    return Some(info);
}

pub fn macos_get_proc_name(proc_info: libc::proc_bsdinfo) -> String {
    match String::from_utf8(proc_info.pbi_name.iter().map(|&c| c as u8).collect()) {
        Ok(val) => val,
        Err(_) => String::new(),
    }
}

pub fn macos_get_proc_comm(proc_info: libc::proc_bsdinfo) -> String {
    match String::from_utf8(proc_info.pbi_comm.iter().map(|&c| c as u8).collect()) {
        Ok(val) => val,
        Err(_) => String::new(),
    }
}

pub fn macos_get_all_processes(pid: PID) -> TreeNode {
    let mut head_node = TreeNode {
        pid,
        stime: 0,
        utime: 0,
        children: Vec::new(),
    };
    let mut task: libc::proc_taskinfo = unsafe { mem::zeroed() };
    let taskinfo_size = mem::size_of::<libc::proc_taskinfo>() as i32;
    if unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKINFO,
            0,
            &mut task as *mut _ as *mut c_void,
            taskinfo_size,
        )
    } != taskinfo_size
    {
        return head_node;
    }
    head_node.stime = task.pti_total_system;
    head_node.utime = task.pti_total_user;
    macos_get_process(&mut head_node);
    head_node
}

fn macos_get_process(tree_node: &mut TreeNode) {
    let num_procs = unsafe { libc::proc_listallpids(ptr::null_mut(), 0) };
    let mut processes: [PID; PID_LIST_MAX] = [0; PID_LIST_MAX];
    unsafe {
        libc::proc_listallpids(
            &mut processes as *mut _ as *mut c_void,
            mem::size_of::<PID>() as i32 * num_procs,
        )
    };
    for pid in processes {
        if pid == 0 {
            continue;
        }
        let mut proc: libc::proc_bsdinfo = unsafe { mem::zeroed() };
        let bsdinfo_size = mem::size_of::<libc::proc_bsdinfo>() as i32;
        if unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                &mut proc as *mut _ as *mut c_void,
                bsdinfo_size,
            )
        } != bsdinfo_size
        {
            continue;
        }
        if proc.pbi_ppid as i32 == tree_node.pid {
            let mut task: libc::proc_taskinfo = unsafe { mem::zeroed() };
            let taskinfo_size = mem::size_of::<libc::proc_taskinfo>() as i32;
            if unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTASKINFO,
                    0,
                    &mut task as *mut _ as *mut c_void,
                    taskinfo_size,
                )
            } != taskinfo_size
            {
                continue;
            }
            let mut child = TreeNode {
                pid: proc.pbi_pid as i32,
                stime: task.pti_total_system,
                utime: task.pti_total_user,
                children: Vec::new(),
            };
            macos_get_process(&mut child);
            tree_node.children.push(child);
        }
    }
}

pub fn macos_get_runtime(starttime: u64) -> u64 {
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs();
    since_epoch - starttime
}

pub fn macos_monitor_stats(pid: PID, files: Files, stats: ForkFlagTuple) {
    let existing_cpu_time = Arc::new(Mutex::new(0));
    let (memory_limit, _, _) = stats;
    loop {
        // Get usage metrics
        let process_tree = macos_get_all_processes(pid);
        save_task_processes(&files.process_dir, &process_tree);

        // Sleep for measuring usage over time
        thread::sleep(Duration::from_secs(1));

        // Check for any alive processes
        let usage_stats = Arc::new(Mutex::new(HashMap::new()));
        let keep_running = Arc::new(Mutex::new(false));
        search_tree(&process_tree, &|node: &TreeNode| {
            if macos_proc_exists(node.pid) {
                if let Some(task_info) = macos_get_task_stats(node.pid) {
                    *keep_running.lock().unwrap() = !(
                        memory_limit != -1 && task_info.pti_resident_size > memory_limit as u64
                    );
                } else {
                    *keep_running.lock().unwrap() = false;
                }
                // Set cpu usage down here
                let (cpu_usage, cpu_time) = macos_get_cpu_usage(node);
                usage_stats
                    .lock()
                    .unwrap()
                    .insert(node.pid, UsageStats { cpu_usage });
                *existing_cpu_time.lock().unwrap() = cpu_time;
            }
        });
        if !*keep_running.lock().unwrap() {
            break;
        }
        save_usage_stats(&files.process_dir, &usage_stats.lock().unwrap());
    }
}

pub fn macos_kill_all_processes(pid: PID) -> Result<(), MultErrorTuple> {
    let mut processes: Vec<PID> = Vec::new();
    compress_tree(&macos_get_all_processes(pid), &mut processes);
    for child_pid in processes {
        unix_kill_process(child_pid as PID)?;
    }
    Ok(())
}

pub fn macos_proc_exists(pid: PID) -> bool {
    let stats = macos_get_process_stats(pid);
    return stats.is_some();
}
