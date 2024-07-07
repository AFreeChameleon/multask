use std::{ffi::{CString, NulError}, fs::{self, File}, io::Read, mem, path::Path, process::exit, time::{SystemTime, SystemTimeError, UNIX_EPOCH}};

use crate::cpulimit::types::{ProcessFilter, ProcessIterator, Process};

use super::types::get_hz;

pub fn get_boot_time() -> Result<u64, SystemTimeError> {
    let mut uptime = 0;
    let file = File::open("/proc/uptime");
    if file.is_ok() {
        let mut contents = String::new();
        file.unwrap().read_to_string(&mut contents);
        uptime = contents.split_whitespace().nth(0).unwrap().parse::<u64>().unwrap();
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    Ok(now - uptime)
}

pub unsafe fn check_proc() -> Result<i32, NulError> {
    let mut mnt: libc::statfs = unsafe { mem::zeroed() };
    if libc::statfs(CString::new("/proc")?.as_ptr(), &mut mnt) < 0 {
        return Ok(0);
    }
    if mnt.f_type != 0x9fa0 {
        return Ok(0);
    }
    Ok(1)
}

pub unsafe fn init_process_iterator(it: &mut ProcessIterator, filter: ProcessFilter) -> Result<i32, i32> {
    if check_proc().is_err() {
        exit(-2);
    }
    it.dip = Some(Path::new("/proc").to_owned());
    it.filter = filter;
    let boot_time = get_boot_time();
    if boot_time.is_err() {
        return Err(-1);
    }
    it.boot_time = boot_time.unwrap();
    Ok(0)
}

pub fn read_process_info(pid: i32, p: &mut Process) -> Result<i32, i32> {
    p.pid = pid;
    let mut buffer = String::new();
    let mut statfile = match File::open(format!("/proc/{}/stat", p.pid)) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    match statfile.read_to_string(&mut buffer) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    let mut statlines = buffer.split('\n');
    for _ in 0..3 {
        statlines.next();
    }
    p.ppid = statlines.next().unwrap().parse::<i32>().unwrap();
    for _ in 0..10 {
        statlines.next();
    }
    let hz = unsafe { get_hz() };
    p.cputime = statlines.next().unwrap().parse::<u32>().unwrap() * 1000 / hz as u32;
    statlines.next();
    p.cputime += statlines.next().unwrap().parse::<u32>().unwrap() * 1000 / hz as u32;
    for _ in 0..7 {
        statlines.next();
    }
    p.starttime = statlines.next().unwrap().parse::<i32>().unwrap() / hz as i32;
    let mut exefile = match File::open(format!("/proc/{}/cmdline", p.pid)) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    buffer = String::new();
    match exefile.read_to_string(&mut buffer) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    p.command = buffer.to_string();
    Ok(0)
}

pub fn getppid_of(pid: i32) -> Result<i32, i32> {
    let mut buffer = String::new();
    let mut statfile = match File::open(format!("/proc/{}/stat", pid)) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    match statfile.read_to_string(&mut buffer) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    let mut statlines = buffer.split('\n');
    for _ in 0..3 {
        statlines.next();
    }
    Ok(statlines.next().unwrap().parse::<i32>().unwrap())
}

pub fn is_child_of(child_pid: i32, parent_pid: i32) -> Result<bool, i32> {
    let mut ppid = child_pid.clone();
    while ppid > 1 && ppid != parent_pid {
        ppid = getppid_of(ppid)?;
    }
    Ok(ppid == parent_pid)
}

pub unsafe fn get_next_process(it: &mut ProcessIterator, p: &mut Process) -> Result<i32, i32> {
    if it.dip.is_none() {
        return Err(-1);
    }
    if it.filter.pid != 0 && !it.filter.include_children {
        let info_return = read_process_info(it.filter.pid, p)?;
        if info_return != 0 {
            return Err(-1);
        }
        return Ok(0);
    }
    let dir = fs::read_dir(it.dip.as_ref().unwrap());
    if dir.is_err() {
        it.dip = None;
        return Err(-1);
    }
    for file in dir.unwrap() {
        let file_name = file.unwrap().file_name().to_str().unwrap().parse::<i32>();
        if file_name.is_ok() {
            continue;
        }
        p.pid = file_name.unwrap();
        if it.filter.pid != 0 && it.filter.pid != p.pid && !is_child_of(p.pid, it.filter.pid)? {
            continue;
        }
        read_process_info(p.pid, p);
        break;
    }
    Ok(0)
}

pub fn close_process_iterator(it: &mut ProcessIterator) -> Result<i32, i32> {
    if it.dip == None {
        return Err(1);
    }
    it.dip = None;
    Ok(0)
}

