#![cfg(target_family = "windows")]
use std::{ffi::c_longlong, mem::size_of, os::raw::c_void, ptr, time::{SystemTime, UNIX_EPOCH}};

use windows_sys::Win32::{Foundation::FILETIME, Storage::FileSystem::READ_CONTROL, System::{JobObjects::{QueryInformationJobObject, JOBOBJECTINFOCLASS, JOBOBJECT_BASIC_PROCESS_ID_LIST}, Threading::{GetProcessTimes, OpenProcess}}};

use crate::tree::TreeNode;

fn combine_filetime(ft: &FILETIME) -> u64 {
    return ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
}

fn convert_filetime64_to_unix_epoch(filetime64: u64) -> u64 {
    return (filetime64 / 10000000) - 11644473600;
}

pub fn win_get_all_processes(job: *mut c_void, pid: u32) -> TreeNode {
    let mut result: JOBOBJECT_BASIC_PROCESS_ID_LIST = JOBOBJECT_BASIC_PROCESS_ID_LIST::empty();
    if unsafe { QueryInformationJobObject(
        job,
        3, // JobObjectBasicProcessIdList
        &mut result as *mut JOBOBJECT_BASIC_PROCESS_ID_LIST as *mut c_void,
        std::mem::size_of::<JOBOBJECT_BASIC_PROCESS_ID_LIST>() as u32,
        ptr::null_mut()
    ) } == 0 {
        // Job does not exist
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
    let process = unsafe { OpenProcess(READ_CONTROL, 1, pid as u32) };
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
    }
    // Time the process was started
    let starttime = convert_filetime64_to_unix_epoch(combine_filetime(&lp_creation_time));
    let kernel_time = combine_filetime(&lp_kernel_time);
    let user_time = combine_filetime(&lp_user_time);
    vec![kernel_time.to_string(), user_time.to_string()]
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