use std::{ffi::c_void, mem, ptr};

use crate::proc::PID;

pub fn macos_get_process_stats(pid: PID) -> Option<libc::proc_taskallinfo> {
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

pub fn macos_get_proc_name(proc_info: libc::proc_taskallinfo) -> String {
    return String::from_utf8(proc_info.pbsd.pbi_name.iter().map(|&c| c as u8).collect()).unwrap();
}
