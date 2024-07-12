extern crate core;
extern crate std;

use std::fs::{File};
use std::io::Read;
use std::path::{Path, PathBuf};

use sysinfo::{Pid, System};

use crate::error::{MultError, MultErrorTuple};

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

pub fn kill_process(pid: u32) -> Result<(), MultErrorTuple> {
    let sys = System::new_all();
    if let Some(process) = sys.process(Pid::from_u32(pid)) {
        process.kill();
    } else {
        return Err((MultError::ProcessNotRunning, None))
    }
    Ok(())
}

pub fn kill_all_processes(ppid: u32) -> Result<(), MultErrorTuple> {
    let mut pids: Vec<u32> = Vec::new();
    let parent_path = Path::new("/proc").join(ppid.to_string());
    if !parent_path.exists() || !parent_path.is_dir() {
        return Err((MultError::ProcessNotRunning, None))
    }
    let mut task_path = parent_path.join("task").join(ppid.to_string());
    loop {
        if task_path.exists() {
            let child_path = task_path.join("children");
            if !child_path.exists() {
                task_path = task_path.join("task").join(ppid.to_string());
                continue;
            }
            task_path = task_path.join("task").join(ppid.to_string());
        } else {
            task_path.pop();
            task_path.pop();
            let child_path = task_path.join("children");
            if !child_path.exists() {
                pids.push(ppid);
                break;
            }
            let mut child_file = File::open(child_path).unwrap();
            let mut contents = String::new();
            child_file.read_to_string(&mut contents).unwrap();
            let str_pids = contents.split_whitespace();
            for pid in str_pids {
                let num_pid = pid.parse::<u32>().unwrap();
                pids.push(num_pid);
                kill_all_processes(num_pid)?;
            }
            pids.push(ppid);
            break;
        }
    }
    for pid in pids {
        kill_process(pid)?;
    }
    Ok(())
}
