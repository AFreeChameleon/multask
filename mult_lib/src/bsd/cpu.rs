use std::mem;
use std::ptr;
use std::ffi::{c_void, CString};

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
