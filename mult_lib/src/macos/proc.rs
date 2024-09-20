use std::ptr;

pub fn macos_get_process_stats() {
}

pub fn macos_get_kinfo_procs() -> Option<libc::> {
    let mut args = [
        libc::CTL_KERN,
        libc::KERN_PROC,
        libc::KERN_PROC_ALL,
        0
    ];

    let mut size = 0;
    if unsafe { libc::sysctl(
        &mut args as *mut i32,
        4,
        ptr::null_mut(),
        &mut size,
        ptr::null_mut(),
        0
    ) } < 0 {

    }

    if libc::sysctl(args, 4, )
}
