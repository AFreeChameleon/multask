use std::{thread, time::Duration};

use libc;

use crate::{proc::get_all_processes, tree::search_tree};

static MILS_IN_SECOND: f32 = 1000.0;

pub fn split_limit_cpu(pid: i32, limit: f32) {
    let running_time = MILS_IN_SECOND * (limit / 100.0);
    let idle_time = MILS_IN_SECOND - running_time;
    let mut running = true;
    loop {
        let process_tree = get_all_processes(pid as usize);
        let sig = if running { libc::SIGSTOP } else { libc::SIGCONT };
        let timeout = if running { idle_time } else { running_time };
        search_tree(&process_tree, &|c_pid: usize| {
            unsafe { libc::kill(c_pid as i32, sig) };
        });
        thread::sleep(Duration::from_millis(timeout as u64));
        running = !running;
    }
}

