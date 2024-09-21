#![cfg(target_os = "macos")]
use std::{ffi::c_void, mem, ptr, time::{SystemTime, UNIX_EPOCH}};

use crate::{error::MultErrorTuple, proc::PID, tree::TreeNode};

const PROC_ALL_PIDS: u32 = 1;

pub fn macos_get_process_stats(pid: PID) -> Option<libc::proc_bsdinfo> {
    let mut info: libc::proc_bsdinfo = unsafe { mem::zeroed() };
    let res = unsafe { libc::proc_pidinfo(
        pid,
        libc::PROC_PIDTBSDINFO,
        0,
        &mut info as *mut _ as *mut c_void,
        mem::size_of::<libc::proc_bsdinfo>() as i32
    ) };
    if res != mem::size_of::<libc::proc_bsdinfo>() as i32 {
        return None;
    }
    return Some(info);
}

pub fn macos_get_all_process_stats(pid: PID) -> Option<libc::proc_taskallinfo> {
    let mut info: libc::proc_taskallinfo = unsafe { mem::zeroed() };
    let res = unsafe { libc::proc_pidinfo(
        pid,
        libc::PROC_PIDTASKALLINFO,
        0,
        &mut info as *mut _ as *mut c_void,
        mem::size_of::<libc::proc_taskallinfo>() as i32
    ) };
    if res != mem::size_of::<libc::proc_taskallinfo>() as i32 {
        return None;
    }
    return Some(info);
}

pub fn macos_get_proc_name(proc_info: libc::proc_bsdinfo) -> String {
    match String::from_utf8(proc_info.pbi_name.iter().map(|&c| c as u8).collect()) {
        Ok(val) => val,
        Err(_) => String::new()
    }
}

pub fn macos_get_proc_comm(proc_info: libc::proc_bsdinfo) -> String {
    match String::from_utf8(proc_info.pbi_comm.iter().map(|&c| c as u8).collect()) {
        Ok(val) => val,
        Err(_) => String::new()
    }
}

pub fn macos_get_all_processes(pid: PID) -> TreeNode {
    let mut head_node = TreeNode {
        pid,
        stime: 0,
        utime: 0,
        children: Vec::new()
    };
    macos_get_process(&mut head_node);
    head_node
}

fn macos_get_process(tree_node: &mut TreeNode) {
    let num_procs = unsafe {
        libc::proc_listpids(PROC_ALL_PIDS, 0, ptr::null_mut(), 0)
    };
    let mut processes: Vec<PID> = vec![0; num_procs as usize];
    unsafe { libc::proc_listpids(PROC_ALL_PIDS,
        0,
        &mut processes as *mut _ as *mut c_void,
        mem::size_of::<PID>() as i32 * num_procs
    ) };
    println!("{:?}", processes);
}

pub fn macos_get_runtime(starttime: u64) -> u64 {
    let now = SystemTime::now();
    let since_epoch = now.duration_since(UNIX_EPOCH).unwrap().as_secs();
    since_epoch - starttime
}
