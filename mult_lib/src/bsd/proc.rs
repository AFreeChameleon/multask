use std::{mem, ptr, ffi::{c_void, CString}};
use crate::proc::{get_readable_memory, PID};
use crate::tree::TreeNode;

pub fn bsd_get_process_stats(pid: PID) -> Option<libc::kinfo_proc> {
    let mut errbuf: [i8; 1024] = [0; 1024];
    let dev_null = CString::new("/dev/null").unwrap();
    let kd = unsafe { libc::kvm_openfiles(
        ptr::null(), dev_null.as_ptr() as *const i8, ptr::null(),
        libc::O_RDONLY, &mut errbuf as *mut i8
    ) };
    if kd.is_null() {
        return None;
    }
    let mut num_procs = -1;
    let procs = unsafe {
        libc::kvm_getprocs(kd, libc::KERN_PROC_PID, pid, &mut num_procs)
    };
    if procs.is_null() {
        return None;
    }
    unsafe { Some(*procs) }
}

fn bsd_get_child_processes(ppid: PID) -> Option<Vec<libc::kinfo_proc>> {
    let mut errbuf: [i8; 1024] = [0; 1024];
    let dev_null = CString::new("/dev/null").unwrap();
    let kd = unsafe { libc::kvm_openfiles(
        ptr::null(), dev_null.as_ptr() as *const i8, ptr::null(),
        libc::O_RDONLY, &mut errbuf as *mut i8
    ) };
    if kd.is_null() {
        return None;
    }
    let mut num_procs: i32 = 0;
    let procs = unsafe {
        libc::kvm_getprocs(kd, libc::KERN_PROC_PROC, 0, &mut num_procs)
    };
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

    unsafe { Some(child_procs) }
}

pub fn bsd_get_process_memory(stats: libc::kinfo_proc) -> String {
    get_readable_memory(stats.ki_size as f64)
}

pub fn bsd_get_cpu_usage(stats: libc::kinfo_proc) -> f32 {
    let mut kernel_f_scale: u32 = 0;
    let mut len = mem::size_of::<u32>();
    let param = CString::new("kern.fscale").unwrap();
    if unsafe { libc::sysctlbyname(
        param.as_ptr() as *const i8,
        &mut kernel_f_scale as *mut _ as *mut c_void,
        &mut len as *mut usize,
        ptr::null(),
        0
    ) } == -1 {
        // htop says so
        kernel_f_scale = 2048;
    }
    100.0 * ((stats.ki_pctcpu / kernel_f_scale) as f32)
}

pub fn bsd_get_all_processes(pid: PID) -> TreeNode {
    let mut errbuf: [i8; 1024] = [0; 1024];
    let dev_null = CString::new("/dev/null").unwrap();
    let kd = unsafe { libc::kvm_openfiles(
        ptr::null(), dev_null.as_ptr() as *const i8, ptr::null(),
        libc::O_RDONLY, &mut errbuf as *mut i8
    ) };
    let mut num_procs = -1;
    let procs = unsafe {
        libc::kvm_getprocs(kd, libc::KERN_PROC_PROC, pid, &mut num_procs)
    };
    let mut head_node = TreeNode {
        pid,
        utime: 0,
        stime: 0,
        children: Vec::new()
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

