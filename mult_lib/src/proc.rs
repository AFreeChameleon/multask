extern crate core;
extern crate std;

use std::env;
use std::fs::{self, File};
use std::io::Read;
use std::ffi::CString;
use std::path::{Path, PathBuf};

use sysinfo::{Pid, System};

use crate::cpulimit::cpulimit::set_cpu_limit;
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

pub fn linux_get_proc_cpu_usage(pid: u32) -> Result<i64, MultErrorTuple> {
    let proc_uptime = match fs::read_to_string("/proc/uptime") {
        Ok(val) => val,
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    let proc_stat = match fs::read_to_string(format!("/proc/{}/stat", pid)) {
        Ok(val) => val,
        Err(_) => {
            return Err((MultError::ProcessDirNotExist, None));
        }
    };
    let mut stats = proc_stat.split_whitespace();
    let mut uptime = proc_uptime.split_whitespace();
    let clk_tck = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let user_time_sec = stats.nth(13).unwrap().parse::<i64>().unwrap() / clk_tck;
    let kernel_time_sec = stats.nth(14).unwrap().parse::<i64>().unwrap() / clk_tck;
    let start_time_sec = stats.nth(21).unwrap().parse::<i64>().unwrap() / clk_tck;
    let usage_sec = user_time_sec + kernel_time_sec;
    let sys_uptime_sec = uptime.nth(0).unwrap().parse::<f64>().unwrap() as i64;
    let elapsed_sec = sys_uptime_sec - start_time_sec;
    let usage_percentage = usage_sec * 100 / elapsed_sec;
    Ok(usage_percentage)
}

pub struct UserCgroup {
    pub memory_limit: i64,
    pub cpu_shares: u64,
    pub task_id: u32,
    pub path: Option<PathBuf>
}

impl UserCgroup {
    pub fn add_user(&mut self) -> Result<(), MultErrorTuple> {
        let user = match env::var("USER") {
            Ok(val) => val,
            Err(_) => return Err((MultError::OSNotSupported, None))
        };
        let user_cg_path = Path::new("/sys/fs/cgroup/mult/").join(&user);
        if !user_cg_path.exists() || !user_cg_path.is_dir() {
            // Create cgroup
            match fs::create_dir(&user_cg_path) {
                Ok(_) => (),
                Err(_) => return Err((MultError::CgroupsMissing, None))
            };
        }
        self.path = Some(user_cg_path.to_path_buf());
        Ok(())
    }

    pub fn add_task(
        &mut self,
        pid: u32
    ) -> Result<(), MultErrorTuple> {
        if self.path.is_none() {
            return Err((MultError::CgroupsMissing, None))
        }
        let path = self.path.clone().unwrap();
        let task_cg_path = path.join(self.task_id.to_string());
        if !task_cg_path.exists() {
            match fs::create_dir(task_cg_path) {
                Ok(_) => (),
                Err(_) => return Err((MultError::CgroupsMissing, None))
            };
        }

        // Writing to CPU
        fs::write(path.join("cpu.weight"), self.cpu_shares.to_string()).unwrap();
        // Writing to Memory
        fs::write(path.join("memory.limit_in_bytes"), self.memory_limit.to_string()).unwrap();
        // Assigning PID
        fs::write(path.join("cgroup.procs"), pid.to_string()).unwrap();
        Ok(())
    }
}

pub unsafe fn init_cgroup() -> Option<i32> {
    let mult_dir = CString::new("/sys/fs/cgroup/mult").unwrap();
    if libc::mkdir(mult_dir.as_ptr(), 0755) != 0 {
        return libc::__errno_location().as_ref().copied();
    }

    if libc::chmod(mult_dir.as_ptr(), 0755) != 0 {
        return libc::__errno_location().as_ref().copied();
    }

    None
}

pub unsafe fn limit_cpu(pid: i32, limit: i32) {
    set_cpu_limit(pid, limit);
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
            break;
        }
    }
    for pid in pids {
        kill_process(pid)?;
    }
    Ok(())
}
