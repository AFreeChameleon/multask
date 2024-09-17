use crate::error::{MultError, MultErrorTuple};

pub fn unix_proc_exists(pid: i32) -> bool {
    #[cfg(target_os = "freebsd")] {
        use crate::bsd::proc::bsd_proc_exists;
        return bsd_proc_exists(pid);
    }
    return unsafe { libc::kill(pid, 0) } == 0;
}

pub fn unix_get_error_code(pid: i32) -> i32 {
    let errno;
    #[cfg(target_os = "linux")] {
        errno = unsafe { *libc::__errno_location() };
    }
    #[cfg(target_os = "freebsd")] {
        errno = unsafe { *libc::__error() };
    }
    return errno;
}

pub fn unix_kill_process(pid: i32) -> Result<(), MultErrorTuple> {
    let res = unsafe { libc::kill(pid, libc::SIGINT) };
    if res == 0 {
        return Ok(());
    }
    let errno = unix_get_error_code(pid);
    Err((MultError::UnixError, Some(errno.to_string())))
}
