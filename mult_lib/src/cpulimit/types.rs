use std::{collections::HashMap, fs::{DirEntry, File}, path::PathBuf};

pub static PIDHASH_SZ: i32 = 1024;
pub static TIME_SLOT : i32 = 100000;
pub static MIN_DT: u64 = 20;
pub static ALFA: f64 = 0.08;
pub static MAX_PRIORITY: i32 = -10;

pub unsafe fn get_hz() -> i64 {
    return libc::sysconf(libc::_SC_CLK_TCK);
}

pub struct ProcessFilter {
	pub pid: i32,
	pub include_children: bool,
	pub program_name: String
}

pub struct ProcessIterator {
	pub dip: Option<PathBuf>,
	pub boot_time: u64,
	pub filter: ProcessFilter
}

#[cfg(target_os = "linux")]
#[derive(Clone)]
pub struct Process {
    pub pid: i32,
    pub ppid: i32,
    pub starttime: i32,
    pub cputime: u32,
    pub cpu_usage: f64,
    pub command: String
}

#[derive(Clone)]
pub struct ProcessGroup {
    pub proctable: HashMap<i32, Vec<Process>>,
    pub proclist: Vec<Process>,
    pub target_pid: i32,
    pub include_children: bool,
    pub last_update: u64,
}

