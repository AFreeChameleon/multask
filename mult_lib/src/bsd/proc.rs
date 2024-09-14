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

pub fn bsd_get_process_memory(pid: &PID) -> String {
    let mut procstats = unsafe { libc::procstat_open_sysctl() };
    let mut ncount = 0;
    let kprocinfo = unsafe { *libc::procstat_getprocs(
        procstats,
        libc::KERN_PROC_PID,
        pid.to_owned() as i32,
        &mut ncount
    ) };
    get_readable_memory(kprocinfo.ki_size as f64)
}

pub fn bsd_get_cpu_usage(stats: libc::kinfo_proc) -> f32 {
    let mut kernelFScale;
    if libc::sysctlbyname(
        "kern.fscale",
        &mut kernelFScale,
        mem::size_of:<i32>:(),
        ptr::null(),
        0
    ) == -1 {
        // htop says so
        kernelFScale = 2048;
    }
    100.0 * (stats.ki_pctcpu / kernelFScale as f32)
}
