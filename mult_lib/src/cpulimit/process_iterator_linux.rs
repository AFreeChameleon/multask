use std::{fs::File, io::Read, path::Path, process::exit, simd::ptr, time::{SystemTime, UNIX_EPOCH}};

use crate::error::{MultError, MultErrorTuple};
use crate::cpulimit::types::{ProcessFilter, ProcessIterator, Process, HZ};

pub fn get_boot_time() -> Result<i32, MultErrorTuple> {
    let uptime = 0;
    let mut file = File::open("/proc/uptime");
    if file.is_ok() {
        let mut contents = String::new();
        file.unwrap().read_to_string(&mut contents);
        uptime = contents.split_whitespace().nth(0).unwrap().parse::<i32>().unwrap();
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?;
    Ok(now - uptime);
}

pub unsafe fn check_proc() -> Result<i32, MultErrorTuple> {
    let mnt: libc::statfs;
    if libc::statfs("/proc", &mnt) < 0 {
        Ok(0);
    }
    if mnt.f_type != 0x9fa0 {
        Ok(0);
    }
    Ok(1)
}

pub unsafe fn init_process_iterator(it: &mut ProcessIterator, filter: ProcessFilter) -> Result<i32, MultErrorTuple> {
    if !check_proc()? {
        exit(-2);
    }
    it.dip = match File::open("/proc") {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    it.filter = filter;
    it.boot_time = get_boot_time();
    Ok(0)
}

pub fn read_process_info(pid: i32, p: &mut Process) -> Result<i32, MultErrorTuple> {
    p.pid = pid;
    let mut buffer = String::new();
    let statfile = match File::open(format!("/proc/{}/stat", p.pid)) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    match statfile.read_to_string(&mut buffer) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    let statlines = buffer.split('\n');
    for i in 0..3 {
        statlines.next();
    }
    p.ppid = statlines.next().unwrap().parse::<i32>();
    for i in 0..10 {
        statlines.next();
    }
    p.cputime = statlines.next().unwrap().parse::<i32>() * 1000 / HZ;
    statlines.next();
    p.cputime += statlines.next().unwrap().parse::<i32>() * 1000 / HZ;
    for i in 0..7 {
        statlines.next();
    }
    p.starttime = statlines.next().unwrap().parse::<i32>() / HZ;
    let exefile = match File::open(format!("/proc/{}/cmdline", p.pid)) {
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

pub fn getppid_of(pid: i32) -> Result<i32, MultErrorTuple> {
    let mut buffer = String::new();
    let statfile = match File::open(format!("/proc/{}/stat", pid)) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    match statfile.read_to_string(&mut buffer) {
        Ok(val) => val,
        Err(_) => return Err(-1)
    };
    let statlines = buffer.split('\n');
    for i in 0..3 {
        statlines.next();
    }
    Ok(statlines.next().unwrap().parse::<i32>())
}

pub fn is_child_of(child_pid: i32, parent_pid: i32) -> Result<bool, MultErrorTuple> {
    let mut ppid = child_pid.clone();
    while ppid > 1 && ppid != parent_pid {
        ppid = getppid_of(ppid);
    }
    Ok(ppid == parent_pid)
}

pub unsafe fn get_next_process(it: &mut ProcessIterator, p: &mut Process) -> Result<i32, MultErrorTuple> {
    if it.dip == None {
        Err(-1)
    }
    if it.filter.pid != 0 && !it.filter.include_children {
        let info_return = read_process_info(it.filter.pid, &mut p)?;
        if info_return != 0 {
            Err(-1)
        }
        Ok(0)
    }
    let mut dit = libc::readdir(it.dip) as *mut libc::dirent;
    while !dit.is_null() {
        let mut d_name = &dit.as_mut().unwrap().d_name;
        if !libc::strtok(d_name, "0123456789").is_null() {
            continue;
        }
        p.pid = String::from_utf16(d_name).unwrap().parse::<i32>();
        if it.filter.pid != 0 && it.filter.pid != p.pid && !is_child_of(p.pid, it.filter.pid) {
            continue;
        }
        read_process_info(p.pid, p);
        break;
    }
    if dit.is_null() {
        it.dip = None;
        Err(-1)
    }
    Ok(0)
}

pub fn close_process_iterator(it: &mut ProcessIterator) {
    if it.dip == None {
        Err(1)
    }
    it.dip = None;
    Ok(0)
}

