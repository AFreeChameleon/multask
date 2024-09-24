use std::mem;
use std::ptr;

use crate::proc::PID;

const TASK_BASIC_INFO: libc::task_flavor_t = 4;
const THREAD_INFO_MAX: u32 = 1024;

pub fn macos_get_cpu_usage(pid: PID) -> f32 {
    let mut port: libc::task_t = unsafe { mem::zeroed() };
    unsafe { libc::task_for_pid(
        libc::mach_task_self(),
        pid,
        &mut port
    ) };
    let mut tinfo: [i32; 1024] = [0; 1024];
    let mut task_info_count: u32 = THREAD_INFO_MAX;
    let mut kr = unsafe { libc::task_info(
        port,
        TASK_BASIC_INFO,
        tinfo.as_mut_ptr(),
        &mut task_info_count
    ) };
    if kr != libc::KERN_SUCCESS {
        // Return 0%
        return 0.0;
    }

    let mut thread_list: [libc::thread_act_t; THREAD_INFO_MAX as usize] = [0; 1024];
    let thread_list_ptr = Box::new(thread_list.as_mut_ptr());
    let mut thread_count: libc::mach_msg_type_number_t = unsafe { mem::zeroed() };

    let mut thinfo: libc::thread_basic_info = unsafe { mem::zeroed() };
    let mut thread_info_count: libc::mach_msg_type_number_t;

    kr = unsafe { libc::task_threads(
        port,
        Box::into_raw(thread_list_ptr),
        &mut thread_count
    ) };
    if kr != libc::KERN_SUCCESS {
        // Return 0%
        return 0.0;
    }
    let mut tot_cpu = 0;
    let mut basic_info_th: libc::thread_basic_info;

    for i in 0..thread_count {
        thread_info_count = THREAD_INFO_MAX;
        kr = unsafe {
            libc::thread_info(
                thread_list[i as usize],
                libc::THREAD_BASIC_INFO as u32,
                ptr::addr_of_mut!(thinfo) as *mut i32,
                &mut thread_info_count
            )
        };
        if kr != libc::KERN_SUCCESS {
            continue;
        }
        basic_info_th = thinfo.clone();

        if basic_info_th.flags & libc::TH_FLAGS_IDLE == 0 {
            tot_cpu = tot_cpu + basic_info_th.cpu_usage;
        }
    }
    return tot_cpu as f32;
}