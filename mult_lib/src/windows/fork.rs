#![cfg(target_family = "windows")]

use home;
use std::{collections::HashMap, env, ffi::{c_void, CString}, mem, path::Path, process::Command, ptr, sync::{Arc, Mutex}, thread, time::Duration};
use windows_sys::{core::{PSTR, PWSTR}, Win32::{
    Foundation::{CloseHandle, GetLastError, FILETIME}, Security::{self, AllocateAndInitializeSid, Authorization::{SetEntriesInAclA, EXPLICIT_ACCESS_A, SET_ACCESS, TRUSTEE_A, TRUSTEE_IS_GROUP, TRUSTEE_IS_SID}, InitializeSecurityDescriptor, SetSecurityDescriptorDacl, ACL, NO_INHERITANCE, SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR, SECURITY_WORLD_SID_AUTHORITY}, Storage::FileSystem::{GetFileInformationByHandleEx, GetFinalPathNameByHandleA, FILE_NAME_INFO, FILE_NAME_NORMALIZED, FILE_STANDARD_INFO}, System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectA, JobObjectCpuRateControlInformation, JobObjectExtendedLimitInformation, JobObjectNotificationLimitInformation, OpenJobObjectA, SetInformationJobObject, TerminateJobObject, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION_0, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION, JOB_OBJECT_CPU_RATE_CONTROL_ENABLE, JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP, JOB_OBJECT_CPU_RATE_CONTROL_MIN_MAX_RATE
        }, SystemInformation::GetSystemTimeAsFileTime, SystemServices::SECURITY_WORLD_RID, Threading::{
            CreateProcessA, CreateProcessW, GetProcessId, WaitForSingleObject, CREATE_NEW_CONSOLE, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, DETACHED_PROCESS, INFINITE, PROCESS_INFORMATION, STARTUPINFOA, STARTUPINFOEXA, STARTUPINFOEXW
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
        let mut command_line = format!(
            "{} {} \"{}\" {}",
            spawn_dir.join("mult_spawn.exe").display().to_string(),
            files.process_dir.display().to_string(),
            command,
            task_id
        );
        unsafe {
            let mut process_info = std::mem::zeroed();
            let mut si: STARTUPINFOEXA = std::mem::zeroed();
            si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXA>() as u32;
            if CreateProcessA(
                ptr::null(),
                command_line.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                CREATE_NO_WINDOW,
                ptr::null(),
                ptr::null(),
                &si.StartupInfo,
                &mut process_info,
            ) == 0 {
                print_error(MultError::WindowsError, Some(GetLastError().to_string()));
                return Err((MultError::ExeDirNotFound, None))
            }
            let lp_name = CString::new(format!("mult-{}", task_id)).unwrap();
            let find_lp_name = CString::new(format!("mult-{}", task_id)).unwrap();
            // Check if job object exists already
            let mut job = OpenJobObjectA(
                0x0001 | 0x0002, // JOB_OBJECT_ALL_ACCESS
                0,
                find_lp_name.as_ptr() as *const u8,
            );
            if job.is_null() {
                let mut p_everyone_sid: *mut c_void = mem::zeroed();
                AllocateAndInitializeSid(
                    &SECURITY_WORLD_SID_AUTHORITY,
                    1,
                    SECURITY_WORLD_RID as u32,
                    0, 0, 0, 0, 0, 0, 0,
                    &mut p_everyone_sid
                );
                let mut lp_sec_desc: SECURITY_DESCRIPTOR = unsafe { mem::zeroed() };
                let ea = EXPLICIT_ACCESS_A {
                    grfAccessPermissions: 0xF003F, // KEY_ALL_ACCESS
                    grfAccessMode: SET_ACCESS,
                    grfInheritance: NO_INHERITANCE,
                    Trustee: TRUSTEE_A {
                        TrusteeForm: TRUSTEE_IS_SID,
                        TrusteeType: TRUSTEE_IS_GROUP,
                        ptstrName: p_everyone_sid as *mut u8,
                        pMultipleTrustee: ptr::null_mut(),
                        MultipleTrusteeOperation: mem::zeroed()
                    }
                };
                let mut p_acl: ACL = mem::zeroed();
                SetEntriesInAclA(
                    1,
                    &ea,
                    ptr::null(),
                    &mut (&mut p_acl as *mut ACL) as *mut *mut ACL // This is HIDEOUS
                );
                InitializeSecurityDescriptor(
                    cast_to_c_void::<SECURITY_DESCRIPTOR>(&mut lp_sec_desc),
                    1u32 // 1u32 is SECURITY_DESCRIPTOR_REVISION
                );
                SetSecurityDescriptorDacl(
                    cast_to_c_void::<SECURITY_DESCRIPTOR>(&mut lp_sec_desc),
                    1,
                    &p_acl,
                    0
                );
                let lp_job_attributes = SECURITY_ATTRIBUTES {
                    nLength: mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                    bInheritHandle: 0,
                    lpSecurityDescriptor: cast_to_c_void::<SECURITY_DESCRIPTOR>(&mut lp_sec_desc)
                };
                job = CreateJobObjectA(
                    &lp_job_attributes,
                    lp_name.as_ptr() as *const u8,
                );
                let mut fp = String::new();
                GetFinalPathNameByHandleA(job, fp.as_mut_ptr(), 1024, FILE_NAME_NORMALIZED);
                let mut fileinformationclass: FILE_NAME_INFO = unsafe { mem::zeroed() };
                GetFileInformationByHandleEx(
                    job,
                    2,
                    cast_to_c_void::<FILE_NAME_INFO>(&mut fileinformationclass),
                    mem::size_of::<FILE_NAME_INFO>() as u32
                );
                println!("{:?} {} {:?} {}", job, job.is_null(), fileinformationclass.FileName, GetLastError());
            }
            if flags.memory_limit != -1 {
                let job_limit_info = JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION {
                    IoReadBytesLimit: std::mem::zeroed(),
                    IoWriteBytesLimit: std::mem::zeroed(),
                    PerJobUserTimeLimit: std::mem::zeroed(),
                    JobMemoryLimit: flags.memory_limit as u64,
                    RateControlTolerance: std::mem::zeroed(),
                    RateControlToleranceInterval: std::mem::zeroed(),
                    LimitFlags: std::mem::zeroed(),
                };
                SetInformationJobObject(
                    job,
                    JobObjectNotificationLimitInformation,
                    std::ptr::addr_of!(job_limit_info) as *const c_void,
                    std::mem::size_of::<JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION>() as u32,
                );
            }
            if flags.cpu_limit != -1 {
                let job_limit_info = JOBOBJECT_CPU_RATE_CONTROL_INFORMATION {
                    ControlFlags: JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP
                        | JOB_OBJECT_CPU_RATE_CONTROL_ENABLE,
                    Anonymous: JOBOBJECT_CPU_RATE_CONTROL_INFORMATION_0 {
                        CpuRate: (10000 / flags.cpu_limit) as u32,
                    },
                };
                SetInformationJobObject(
                    job,
                    JobObjectCpuRateControlInformation,
                    std::ptr::addr_of!(job_limit_info) as *const c_void,
                    std::mem::size_of::<JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION>() as u32,
                );
            }
            AssignProcessToJobObject(job, process_info.hProcess);
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
