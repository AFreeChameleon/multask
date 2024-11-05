#![cfg(target_family = "windows")]
use std::{
    ffi::OsString,
    mem,
    os::{
        raw::c_void,
        windows::ffi::{OsStrExt, OsStringExt},
    },
    ptr,
    time::{SystemTime, UNIX_EPOCH},
};

use windows_sys::Win32::{
    Foundation::{GetLastError, FILETIME, STILL_ACTIVE},
    Storage::FileSystem::SYNCHRONIZE,
    System::{
        JobObjects::{OpenJobObjectW, QueryInformationJobObject, JOBOBJECT_BASIC_PROCESS_ID_LIST},
        ProcessStatus::{GetProcessImageFileNameW, GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
        Threading::{
            GetExitCodeProcess, GetProcessTimes, OpenProcess, TerminateProcess, PROCESS_ALL_ACCESS,
            PROCESS_QUERY_INFORMATION, PROCESS_TERMINATE,
        },
    },
};

use crate::{
    error::{print_error, print_warning, MultError, MultErrorTuple},
    proc::{get_readable_memory, PID},
    tree::{compress_tree, TreeNode},
};

use super::fork::cast_to_c_void;

pub fn combine_filetime(ft: &FILETIME) -> u64 {
    return ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
}

fn convert_filetime64_to_unix_epoch(filetime64: u64) -> u64 {
    return (filetime64 / 10000000) - 11644473600;
}

pub fn win_get_all_processes(job: *mut c_void, pid: PID) -> TreeNode {
    #[repr(C)]
    struct Jobs {
        header: JOBOBJECT_BASIC_PROCESS_ID_LIST,
        list: [usize; 1024],
    }
    let mut jobs: Jobs = unsafe { mem::zeroed() };
    if unsafe {
        QueryInformationJobObject(
            job,
            3, // JobObjectBasicProcessIdList
            cast_to_c_void::<Jobs>(&mut jobs),
            mem::size_of_val(&jobs) as u32,
            ptr::null_mut(),
        )
    } == 0
    {
        // Job does not exist
        print_error(MultError::WindowsError, unsafe {
            Some(GetLastError().to_string())
        });
        return TreeNode::empty();
    }
    let list = &jobs.list[..jobs.header.NumberOfProcessIdsInList as usize];
    let mut stats = win_get_process_stats(pid);
    let mut head_node = TreeNode {
        pid,
        stime: stats[0].parse().unwrap(),
        utime: stats[1].parse().unwrap(),
        children: Vec::new(),
    };
    for child_pid_ref in list {
        let child_pid = child_pid_ref.to_owned() as PID;
        if child_pid == pid || child_pid == 0 {
            continue;
        }
        stats = win_get_process_stats(child_pid);
        head_node.children.push(TreeNode {
            pid: child_pid,
            stime: stats[0].parse().unwrap(),
            utime: stats[1].parse().unwrap(),
            children: Vec::new(),
        });
    }
    return head_node;
}

pub fn win_get_process_stats(pid: PID) -> Vec<String> {
    let process = unsafe { OpenProcess(PROCESS_ALL_ACCESS, 1, pid as u32) };
    let mut lp_creation_time = FILETIME::empty();
    let mut lp_exit_time = FILETIME::empty();
    let mut lp_kernel_time = FILETIME::empty();
    let mut lp_user_time = FILETIME::empty();
    if unsafe {
        GetProcessTimes(
            process,
            &mut lp_creation_time,
            &mut lp_exit_time,
            &mut lp_kernel_time,
            &mut lp_user_time,
        )
    } == 0
    {
        // Unable to get times
        print_error(MultError::FailedToReadProcessStats, None);
        print_error(MultError::WindowsError, unsafe {
            Some(GetLastError().to_string())
        });
        return vec![];
    }
    // Time the process was started
    let starttime = convert_filetime64_to_unix_epoch(combine_filetime(&lp_creation_time));
    let kernel_time = combine_filetime(&lp_kernel_time);
    let user_time = combine_filetime(&lp_user_time);
    vec![
        kernel_time.to_string(),
        user_time.to_string(),
        starttime.to_string(),
    ]
}

pub fn win_get_proc_name(pid: u32) -> Result<String, MultErrorTuple> {
    let mut process_name = [0; 1024];
    let process_handle = unsafe { OpenProcess(PROCESS_QUERY_INFORMATION, 1, pid as u32) };
    if unsafe { GetProcessImageFileNameW(process_handle, process_name.as_mut_ptr(), 1024) } == 0 {
        return Ok(String::new());
    }
    let split_p_name = process_name
        .split(|pchar| *pchar == b'\\'.into())
        .last()
        .unwrap()
        .to_vec();
    let exe_name = String::from_utf16(&split_p_name)
        .unwrap()
        .trim_matches(char::from(0))
        .to_owned();
    Ok(exe_name)
}

pub fn win_proc_exists(pid: u32) -> bool {
    let process_handle = unsafe { OpenProcess(PROCESS_QUERY_INFORMATION, 1, pid) };
    if process_handle.is_null() {
        return false;
    }
    let mut exit_code: u32 = 0;
    if unsafe { GetExitCodeProcess(process_handle, &mut exit_code as *mut u32) } == 0 {
        return false;
    }
    if exit_code != STILL_ACTIVE as u32 {
        return false;
    }
    return true;
}

pub fn win_get_memory_usage(pid: &PID) -> String {
    let process = unsafe { OpenProcess(PROCESS_QUERY_INFORMATION, 1, pid.to_owned() as u32) };
    if process.is_null() {
        return "0 B".to_string();
    }
    unsafe {
        let mut mem_info: PROCESS_MEMORY_COUNTERS = mem::zeroed();
        GetProcessMemoryInfo(
            process,
            &mut mem_info,
            mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        );
        return get_readable_memory(mem_info.WorkingSetSize as f64);
    }
}

pub fn win_get_process_runtime(starttime: u64) -> u64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let runtime = now - starttime;
    runtime
}

pub fn win_kill_all_processes(ppid: u32, task_id: u32) -> Result<(), MultErrorTuple> {
    if !win_proc_exists(ppid) {
        return Err((MultError::ProcessNotExists, None));
    }
    let lp_name = OsString::from(format!("Global\\mult-{}", task_id))
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<u16>>();
    let job = unsafe {
        OpenJobObjectW(
            0x1F001F, // JOB_OBJECT_ALL_ACCESS
            1,
            lp_name.as_ptr() as *const u16,
        )
    };
    let process_tree = win_get_all_processes(job, ppid);
    let mut all_processes = vec![];
    compress_tree(&process_tree, &mut all_processes);
    for pid in all_processes {
        win_kill_process(pid as u32)?;
    }
    if job.is_null() {
        return Ok(());
    }
    Ok(())
}

pub fn win_kill_process(pid: u32) -> Result<(), MultErrorTuple> {
    let mut process_name = [0; 1024];
    let process_handle = unsafe {
        OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_INFORMATION | SYNCHRONIZE,
            1,
            pid as u32,
        )
    };
    if unsafe { GetProcessImageFileNameW(process_handle, process_name.as_mut_ptr(), 1024) } == 0 {
        return unsafe { Err((MultError::WindowsError, Some(GetLastError().to_string()))) };
    }
    let process_name_str = OsString::from_wide(&process_name[..]);

    // This is why I need to check for it
    // https://github.com/rust-lang/rust/issues/33145
    // The gist of it is that all builds on one machine use the same
    // `mspdbsrv.exe` instance. If we were to kill this instance then we
    // could erroneously cause other builds to fail.
    // https://github.com/alexcrichton/rustjob/blob/07d2601c8bf63d06584b2c4e248fd2c65c18d224/src/main.rs#L200
    if let Some(process_name_str) = process_name_str.to_str() {
        if process_name_str.contains("mspdbsrv") {
            return Err((
                MultError::CustomError,
                Some("Cannot kill mspdbsrv.exe".to_string()),
            ));
        }
    }
    if unsafe { TerminateProcess(process_handle, 1) } == 0 {
        unsafe {
            print_warning(&format!(
                "Failed to kill process: {}. error code: {}",
                pid,
                GetLastError()
            ));
        }
    }
    Ok(())
}

trait Empty<T> {
    fn empty() -> T;
}

impl Empty<FILETIME> for FILETIME {
    fn empty() -> FILETIME {
        FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0,
        }
    }
}

impl Empty<JOBOBJECT_BASIC_PROCESS_ID_LIST> for JOBOBJECT_BASIC_PROCESS_ID_LIST {
    fn empty() -> JOBOBJECT_BASIC_PROCESS_ID_LIST {
        JOBOBJECT_BASIC_PROCESS_ID_LIST {
            NumberOfAssignedProcesses: 24,
            NumberOfProcessIdsInList: 24,
            ProcessIdList: [0; 1],
        }
    }
}
