#![cfg(target_family = "windows")]

use home;
use std::{env, path::Path, process::Command};
use windows_sys::Win32::{Foundation::CloseHandle, System::Threading::{CreateProcessA, WaitForSingleObject, CREATE_NO_WINDOW, INFINITE, PROCESS_INFORMATION, STARTUPINFOA}};
use crate::{command::MemStats, error::{MultError, MultErrorTuple}, task::Files};

pub fn run_daemon(files: Files, command: String, flags: &MemStats) -> Result<(), MultErrorTuple> {
    if let Ok(exe_dir) = env::current_exe() {
        let spawn_dir = Path::new(&exe_dir).parent().unwrap();
        let current_dir = match env::current_dir() {
            Ok(val) => val,
            Err(_) => home::home_dir().unwrap()
        };
        let startup_info = STARTUPINFOA::empty();
        let mut process_info = PROCESS_INFORMATION::empty();
        unsafe {
            if CreateProcessA(
                std::mem::zeroed(),
                format!("{} {} {}",
                    spawn_dir.join("mult_spawn.exe").display().to_string(),
                    files.process_dir.display().to_string(),
                    command
                ).as_mut_ptr(),
                std::mem::zeroed(),
                std::mem::zeroed(),
                std::mem::zeroed(),
                CREATE_NO_WINDOW,
                std::mem::zeroed(),
                current_dir.display().to_string().as_ptr(),
                &startup_info,
                &mut process_info
            ) == 1 {
                WaitForSingleObject(process_info.hProcess, INFINITE);
                CloseHandle(process_info.hProcess);
                CloseHandle(process_info.hThread);
            }
        }
    } else {
        return Err((MultError::ExeDirNotFound, None));
    }
    Ok(())
}

trait Empty<T> {
    fn empty() -> T;
}

impl Empty<STARTUPINFOA> for STARTUPINFOA {
    fn empty() -> STARTUPINFOA {
        STARTUPINFOA {
            cb: 0,
            lpReserved: String::new().as_mut_ptr(),
            lpDesktop: String::new().as_mut_ptr(),
            lpTitle: String::new().as_mut_ptr(),
            dwX: 0,
            dwXSize: 0,
            dwYSize: 0,
            dwY: 0,
            dwXCountChars: 0,
            dwYCountChars: 0,
            dwFillAttribute: 0,
            dwFlags: 0,
            wShowWindow: 0,
            cbReserved2: 0,
            lpReserved2: String::new().as_mut_ptr(),
            hStdInput: std::ptr::null_mut(),
            hStdOutput: std::ptr::null_mut(),
            hStdError: std::ptr::null_mut(),
        }
    }
}

impl Empty<PROCESS_INFORMATION> for PROCESS_INFORMATION {
    fn empty() -> PROCESS_INFORMATION {
        PROCESS_INFORMATION {
            hProcess: std::ptr::null_mut(),
            hThread: std::ptr::null_mut(),
            dwProcessId: 0,
            dwThreadId: 0
        }
    }
  }