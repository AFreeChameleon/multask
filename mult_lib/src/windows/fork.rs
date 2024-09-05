#![cfg(target_family = "windows")]

use crate::{
    command::MemStats,
    error::{print_error, MultError, MultErrorTuple},
    task::Files
};
use windows_sys::Win32::{Foundation::GetLastError, System::Threading::{CreateProcessW, CREATE_BREAKAWAY_FROM_JOB, CREATE_NO_WINDOW, DETACHED_PROCESS, STARTUPINFOEXW}};
use std::{
    env, ffi::{c_void, OsString}, os::windows::ffi::OsStrExt, path::Path, ptr
};

pub fn cast_to_c_void<T>(var: &mut T) -> *mut c_void {
    return var as *mut T as *mut c_void;
}

pub fn run_daemon(
    files: Files,
    command: String,
    flags: &MemStats,
    task_id: u32,
) -> Result<(), MultErrorTuple> {
    if let Ok(exe_dir) = env::current_exe() {
        let spawn_dir = Path::new(&exe_dir).parent().unwrap();
        let mut command_line: Vec<u16> = OsString::from(format!(
            "{} {} \"{}\" {} {} {}",
            spawn_dir.join("mult_spawn.exe").display().to_string(),
            files.process_dir.display().to_string(),
            command,
            task_id,
            flags.memory_limit,
            flags.cpu_limit
        )).encode_wide().chain(Some(0)).collect();
        unsafe {
            let mut process_info = std::mem::zeroed();
            let mut si: STARTUPINFOEXW = std::mem::zeroed();
            si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
            if CreateProcessW(
                ptr::null(),
                command_line.as_mut_ptr() as *mut u16,
                ptr::null(),
                ptr::null(),
                0,
                CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB,
                ptr::null(),
                ptr::null(),
                &si.StartupInfo,
                &mut process_info,
            ) == 0
            {
                print_error(MultError::WindowsError, Some(GetLastError().to_string()));
                return Err((MultError::ExeDirNotFound, None));
            }
        }
    } else {
        return Err((MultError::ExeDirNotFound, None));
    }
    Ok(())
}

