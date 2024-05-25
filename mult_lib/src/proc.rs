use std::env;
use std::fs::{self, File};
use std::io::Read;
use std::ffi::CString;
use std::path::{Path, PathBuf};

use cgroups_rs::cgroup_builder::CgroupBuilder;
use cgroups_rs::{Cgroup, CgroupPid, Controller};

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

pub fn create_cgroup(
    mult_id: u32,
    cpu_shares: u64,
    memory_limit: i64
) -> Cgroup {
    let hier = cgroups_rs::hierarchies::auto();

    let mut cgroup_id = "mult".to_owned();
    cgroup_id.push_str(&mult_id.to_string());
    let cg: Cgroup = CgroupBuilder::new(&cgroup_id)
        .cpu()
            .shares(cpu_shares)
            .done()
        .memory()
            .memory_hard_limit(memory_limit)
            .kernel_memory_limit(memory_limit)
            .done()
        .build(hier)
        .unwrap();

    cg
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

