#![cfg(target_family = "windows")]
use std::{ffi::c_longlong, time::{SystemTime, UNIX_EPOCH}};

use windows_sys::Win32::{Foundation::FILETIME, Storage::FileSystem::READ_CONTROL, System::Threading::{GetProcessTimes, OpenProcess}};

fn combine_filetime(ft: &FILETIME) -> u64 {
    return ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
}

fn convert_filetime64_to_unix_epoch(filetime64: u64) -> u64 {
    return (filetime64 / 10000000) - 11644473600;
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
    let starttime = convert_filetime64_to_unix_epoch(combine_filetime(&lp_creation_time));
    Vec::new()
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