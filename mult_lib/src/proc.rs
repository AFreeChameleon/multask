extern crate core;
extern crate std;

use std::fs::{self, File};
use std::io::Read;
use std::path::Path;

use sysinfo::{Pid, System};

use crate::tree::compress_tree;
use crate::{error::{MultError, MultErrorTuple}, tree::TreeNode};

pub fn get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
    let mut proc_name = String::new();
    let mut proc_file = match File::open(format!("/proc/{}/cmdline", pid)) {
        Ok(val) => val,
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    match proc_file.read_to_string(&mut proc_name) {
        Ok(_) => (),
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    Ok(proc_name)
}

pub fn get_proc_comm(pid: u32) -> Result<String, MultErrorTuple> {
    let mut proc_comm = String::new();
    let mut proc_file = match File::open(format!("/proc/{}/comm", pid)) {
        Ok(val) => val,
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    match proc_file.read_to_string(&mut proc_comm) {
        Ok(_) => (),
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    Ok(proc_comm.trim().to_string())
}

pub fn kill_all_processes(ppid: u32) -> Result<(), MultErrorTuple> {
    let sys = System::new_all();
    let process_tree = get_all_processes(ppid as usize);
    let mut all_processes = vec![];
    compress_tree(&process_tree, &mut all_processes);
    if let Some(process) = sys.process(Pid::from_u32(ppid)) {
        if let Some(parent_pid) = process.parent() {
            sys.process(parent_pid).unwrap().kill();
        }
    }
    for pid in all_processes {
        if let Some(process) = sys.process(Pid::from_u32(pid as u32)) {
            process.kill();
        } else {
            return Err((MultError::ProcessNotRunning, None))
        }
    }
    Ok(())
}

pub fn save_task_processes(path: &Path, tree: &TreeNode) {
    let encoded_data = bincode::serialize::<TreeNode>(tree).unwrap();
    fs::write(path.join("processes.bin"), encoded_data).unwrap();
}

pub fn proc_exists(pid: i32) -> bool {
    #[cfg(target_family = "unix")]
    return unsafe { libc::kill(pid, 0) } == 0;
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
