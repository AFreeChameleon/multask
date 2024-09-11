pub fn unix_proc_exists(pid: i32) -> bool {
    return unsafe { libc::kill(pid, 0) } == 0;
}
