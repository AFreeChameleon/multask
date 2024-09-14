use std::{mem, ptr, ffi::{c_void, CString}};
use crate::proc::{get_readable_memory, PID};

pub fn bsd_get_process_stats(pid: PID) -> Option<libc::kinfo_proc> {
    let mut procstats = unsafe { libc::procstat_open_sysctl() };
    let mut ncount = 0;
    let kprocinfo_ptr = unsafe { libc::procstat_getprocs(
        procstats,
        libc::KERN_PROC_PID,
        pid.to_owned() as i32,
        &mut ncount
    ) };
    if kprocinfo_ptr.is_null() {
        return None;
    }
    unsafe { Some(*kprocinfo_ptr) }
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
