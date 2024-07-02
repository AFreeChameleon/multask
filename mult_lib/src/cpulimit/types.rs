use std::{collections::HashMap, fs::File};

pub static HZ: i32 = unsafe {libc::sysconf(libc::_SC_CLK_TCK)};
pub static PIDHASH_SZ: i32 = 1024;
pub static MIN_DT: i32 = 20;
pub static ALFA: f32 = 0.08;

pub struct ProcessFilter {
	pub pid: i32,
	pub include_children: i32,
	pub program_name: String
}

pub struct ProcessIterator {
	pub dip: File,
	pub boot_time: i32,
	pub filter: ProcessFilter
}

#[cfg(target_os = "linux")]
#[derive(Clone)]
pub struct Process {
    pub pid: i32,
    pub ppid: i32,
    pub starttime: i32,
    pub cputime: i32,
    pub cpu_usage: f64,
    pub command: String
}

pub struct ProcessGroup {
    pub proctable: HashMap<i32, Process>,
    pub proclist: Vec,
    pub target_pid: i32,
    pub include_children: i32,
    pub last_update: u64,
}
