#![cfg(target_family = "unix")]
use crate::{
    error::{MultError, MultErrorTuple},
    proc::PID,
};

pub static MILS_IN_SECOND: f32 = 1000.0;

pub fn unix_proc_exists(pid: PID) -> bool {
    #[cfg(target_os = "freebsd")]
    {
        use crate::bsd::proc::bsd_proc_exists;
        return bsd_proc_exists(pid);
    }
    #[cfg(target_os = "macos")]
    {
        use crate::macos::proc::macos_proc_exists;
        return macos_proc_exists(pid);
    }
    #[cfg(target_os = "linux")]
    {
        use crate::linux::proc::linux_proc_exists;
        return linux_proc_exists(pid);
    }
}

pub fn unix_get_error_code() -> i32 {
    let errno;
    #[cfg(target_os = "linux")]
    {
        errno = unsafe { *libc::__errno_location() };
    }
    #[cfg(any(target_os = "freebsd", target_os = "macos"))]
    {
        errno = unsafe { *libc::__error() };
    }
    return errno;
}

pub fn unix_kill_process(pid: PID) -> Result<(), MultErrorTuple> {
    let res = unsafe { libc::kill(pid, libc::SIGINT) };
    if res == 0 {
        return Ok(());
    }
    let errno = unix_get_error_code();
    Err((MultError::UnixError, Some(errno.to_string())))
}

pub fn unix_convert_c_string(c_string: std::slice::Iter<i8>) -> String {
    String::from_utf8(c_string.into_iter().map(|&c| c as u8).collect()).unwrap()
}
