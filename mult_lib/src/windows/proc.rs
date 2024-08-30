#![cfg(target_family = "windows")]
use std::{ffi::c_longlong, mem::{self, size_of}, os::raw::c_void, ptr, time::{SystemTime, UNIX_EPOCH}};

use windows_sys::Win32::{Foundation::{GetLastError, FILETIME}, Storage::FileSystem::READ_CONTROL, System::{JobObjects::{QueryInformationJobObject, JOBOBJECTINFOCLASS, JOBOBJECT_BASIC_PROCESS_ID_LIST}, ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS}, Threading::{GetProcessTimes, OpenProcess, PROCESS_ALL_ACCESS, PROCESS_QUERY_INFORMATION}}};

use crate::{error::{print_error, MultError}, tree::TreeNode};

use super::fork::cast_to_c_void;

pub fn combine_filetime(ft: &FILETIME) -> u64 {
    return ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
}

fn convert_filetime64_to_unix_epoch(filetime64: u64) -> u64 {
    return (filetime64 / 10000000) - 11644473600;
}

pub fn win_get_all_processes(job: &mut c_void, pid: u32) -> TreeNode {
    let mut result: JOBOBJECT_BASIC_PROCESS_ID_LIST = JOBOBJECT_BASIC_PROCESS_ID_LIST::empty();
    if unsafe { QueryInformationJobObject(
        job,
        3, // JobObjectBasicProcessIdList
        cast_to_c_void::<JOBOBJECT_BASIC_PROCESS_ID_LIST>(&mut result),
        std::mem::size_of::<JOBOBJECT_BASIC_PROCESS_ID_LIST>() as u32,
        ptr::null_mut()
    ) } == 0 {
        // Job does not exist
        print_error(MultError::ProcessNotExists, None);
        return TreeNode::empty();
    }
    let mut stats = win_get_process_stats(pid as usize);
    let mut head_node = TreeNode {
        pid: pid as usize,
        stime: stats[0].parse().unwrap(),
        utime: stats[1].parse().unwrap(),
        children: Vec::new()
    };
    for child_pid in result.ProcessIdList {
        stats = win_get_process_stats(child_pid as usize);
        head_node.children.push(TreeNode {
            pid: child_pid,
            stime: stats[0].parse().unwrap(),
            utime: stats[1].parse().unwrap(),
            children: Vec::new()
        });
    }
    return head_node;
}

pub fn win_get_process_stats(pid: usize) -> Vec<String> {
    let process = unsafe { OpenProcess(PROCESS_ALL_ACCESS, 1, pid as u32) };
    let mut lp_creation_time = FILETIME::empty();
    let mut lp_exit_time = FILETIME::empty();
    let mut lp_kernel_time = FILETIME::empty();
    let mut lp_user_time = FILETIME::empty();
    if unsafe { GetProcessTimes(
        process,
        &mut lp_creation_time,
        &mut lp_exit_time,
        &mut lp_kernel_time,
        &mut lp_user_time
    ) } == 0 {
        // Unable to get times
        print_error(MultError::FailedToReadProcessStats, None);
        print_error(MultError::WindowsError, unsafe { Some(GetLastError().to_string()) });
        return vec![];
    }
    // Time the process was started
    let starttime = convert_filetime64_to_unix_epoch(combine_filetime(&lp_creation_time));
    let kernel_time = combine_filetime(&lp_kernel_time);
    let user_time = combine_filetime(&lp_user_time);
    vec![kernel_time.to_string(), user_time.to_string(), starttime.to_string()]
}

pub fn win_get_memory_usage(pid: &usize) -> String {
    let process = unsafe { OpenProcess(PROCESS_QUERY_INFORMATION, 1, pid.to_owned() as u32) };
    if process.is_null() {
        return "0 b".to_string();
    }
    unsafe {
        let mut mem_info: PROCESS_MEMORY_COUNTERS = mem::zeroed();
        GetProcessMemoryInfo(process, &mut mem_info, mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32);
        return format!("{} b", mem_info.WorkingSetSize);
    }
}

pub fn win_get_process_runtime(starttime: u64) -> u64 {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let runtime = now - convert_filetime64_to_unix_epoch(starttime);
    runtime
}

trait Empty<T> {
    fn empty() -> T;
}

impl Empty<FILETIME> for FILETIME {
    fn empty() -> FILETIME {
        FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0
        }
    }
}

impl Empty<JOBOBJECT_BASIC_PROCESS_ID_LIST> for JOBOBJECT_BASIC_PROCESS_ID_LIST {
    fn empty() -> JOBOBJECT_BASIC_PROCESS_ID_LIST {
        JOBOBJECT_BASIC_PROCESS_ID_LIST {
            NumberOfAssignedProcesses: 0,
            NumberOfProcessIdsInList: 0,
            ProcessIdList: [0]
        }
    }
}