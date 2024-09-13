use crate::proc::get_readable_memory;

pub fn bsd_get_process_stats(pid: i32) -> Option<libc::kinfo_proc> {
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

pub fn bsd_get_process_memory(pid: &usize) -> String {
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
