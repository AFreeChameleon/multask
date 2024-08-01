use std::{fs, path::Path, sync::{Arc, Mutex}, thread, time::Duration};

use libc;

use crate::tree::{search_tree, TreeNode};

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

pub fn get_all_processes(pid: usize) -> TreeNode {
    #[cfg(target_os = "linux")]
    return linux_get_all_processes(pid);
}

// uses proc api
fn linux_get_all_processes(pid: usize) -> TreeNode {
    let mut head_node = TreeNode {
        pid,
        children: Vec::new()
    };
    linux_get_process(pid, &mut head_node);
    return head_node;
}

fn linux_get_process(pid: usize, tree_node: &mut TreeNode) {
    let initial_proc = format!("/proc/{}/", pid).to_owned();
    let proc_path = Path::new(&initial_proc);
    if proc_path.exists() {
        let child_path = proc_path.join("task").join(pid.to_string()).join("children");
        if child_path.exists() {
            let contents = fs::read_to_string(child_path).unwrap();
            let child_pids = contents.split_whitespace();
            for c_pid in child_pids {
                let usize_c_pid = c_pid.parse::<usize>().unwrap();
                let mut new_node = TreeNode {
                    pid: usize_c_pid,
                    children: Vec::new()
                };
                linux_get_process(usize_c_pid, &mut new_node);
                tree_node.children.push(new_node);            
            }
        }
    }
}
