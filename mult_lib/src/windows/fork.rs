#![cfg(target_family = "windows")]

use home;
use std::{collections::HashMap, env, ffi::{c_void, CString}, mem, path::Path, process::Command, ptr, sync::{Arc, Mutex}, thread, time::Duration};
use windows_sys::{core::{PSTR, PWSTR}, Win32::{
    Foundation::{CloseHandle, GetLastError, ERROR_SUCCESS, FILETIME}, Security::{self, AllocateAndInitializeSid, Authorization::{ConvertSidToStringSidA, SetEntriesInAclA, EXPLICIT_ACCESS_A, NO_MULTIPLE_TRUSTEE, SET_ACCESS, TRUSTEE_A, TRUSTEE_IS_GROUP, TRUSTEE_IS_NAME, TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_IS_WELL_KNOWN_GROUP}, InitializeSecurityDescriptor, SetSecurityDescriptorDacl, ACL, NO_INHERITANCE, PSID, SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR, SECURITY_WORLD_SID_AUTHORITY}, Storage::FileSystem::{GetFileInformationByHandleEx, GetFinalPathNameByHandleA, FILE_NAME_INFO, FILE_NAME_NORMALIZED, FILE_STANDARD_INFO}, System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectA, JobObjectCpuRateControlInformation, JobObjectExtendedLimitInformation, JobObjectNotificationLimitInformation, OpenJobObjectA, SetInformationJobObject, TerminateJobObject, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION_0, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION, JOB_OBJECT_CPU_RATE_CONTROL_ENABLE, JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP, JOB_OBJECT_CPU_RATE_CONTROL_MIN_MAX_RATE, JOB_OBJECT_LIMIT_BREAKAWAY_OK
        }, Registry::{KEY_ALL_ACCESS, KEY_READ}, SystemInformation::GetSystemTimeAsFileTime, SystemServices::{DOMAIN_ALIAS_RID_ADMINS, SECURITY_BUILTIN_DOMAIN_RID, SECURITY_DESCRIPTOR_REVISION, SECURITY_WORLD_RID}, Threading::{
            CreateProcessA, CreateProcessW, GetProcessId, WaitForSingleObject, CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_CONSOLE, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, DETACHED_PROCESS, INFINITE, PROCESS_INFORMATION, STARTUPINFOA, STARTUPINFOEXA, STARTUPINFOEXW
        }
    }
}};
use crate::{
    command::MemStats, error::{print_error, MultError, MultErrorTuple}, proc::{get_all_processes, proc_exists, save_task_processes, save_usage_stats, UsageStats}, task::Files, tree::{search_tree, TreeNode}
};

use super::{cpu::win_get_cpu_usage, proc::{combine_filetime, win_get_all_processes}};

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
        let command_line = CString::new(format!(
            "{} {} \"{}\" {} {} {}",
            spawn_dir.join("mult_spawn.exe").display().to_string(),
            files.process_dir.display().to_string(),
            command,
            task_id,
            flags.memory_limit,
            flags.cpu_limit
        )).unwrap();
        let mut command_line_str: Vec<u8> = command_line.as_bytes_with_nul().to_owned();
        unsafe {
            let mut process_info = std::mem::zeroed();
            let mut si: STARTUPINFOEXW = std::mem::zeroed();
            si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXA>() as u32;
            if CreateProcessW(
                ptr::null(),
                command_line_str.as_mut_ptr() as *mut u16,
                ptr::null(),
                ptr::null(),
                0,
                CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB,
                ptr::null(),
                ptr::null(),
                &si.StartupInfo,
                &mut process_info,
            ) == 0 {
                print_error(MultError::WindowsError, Some(GetLastError().to_string()));
                return Err((MultError::ExeDirNotFound, None))
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
            dwThreadId: 0,
        }
    }
}
