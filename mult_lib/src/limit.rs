use std::{thread, time::Duration};

use libc;

static MILS_IN_SECOND: f32 = 1000.0;

// ADD CHECK IF PROCESS DOESN'T EXIST
unsafe fn next(pid: i32, running: bool, idle_time: i32, running_time: i32) {
    let mut timeout: Option<i32> = None;
    let sig = if running { libc::SIGSTOP } else { libc::SIGCONT };
    let kill_ret = libc::kill(pid, sig);
    if kill_ret == 0 {
        timeout = if running { Some(idle_time) } else { Some(running_time) };
    }
    if timeout.is_some() {
        thread::sleep(Duration::from_millis(timeout.unwrap() as u64));
        next(pid, !running, idle_time, running_time);
    } else {
        return
    }
}

pub fn limit_cpu(pid: i32, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let running = true;
    unsafe { next(pid, running, idle_time as i32, running_time as i32); }
}

