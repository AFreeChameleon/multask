use std::fs::File;

pub static HZ: i32 = unsafe {libc::sysconf(libc::_SC_CLK_TCK)};

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

pub struct Process {
	pub pid: i32,
	pub ppid: i32,
	pub starttime: i32,
	pub cputime: i32,
	pub cpu_usage: f64,
	pub command: String
}
