#![cfg(target_family = "windows")]

use home;
use std::{collections::HashMap, env, ffi::c_void, mem, path::Path, process::Command, sync::{Arc, Mutex}, thread, time::Duration};
use windows_sys::Win32::{
    Foundation::{CloseHandle, FILETIME},
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectA, JobObjectCpuRateControlInformation, JobObjectExtendedLimitInformation, JobObjectNotificationLimitInformation, OpenJobObjectA, SetInformationJobObject, TerminateJobObject, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION_0, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION, JOB_OBJECT_CPU_RATE_CONTROL_ENABLE, JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP, JOB_OBJECT_CPU_RATE_CONTROL_MIN_MAX_RATE
        }, SystemInformation::GetSystemTimeAsFileTime, Threading::{
            CreateProcessA, GetProcessId, WaitForSingleObject, CREATE_NO_WINDOW, INFINITE, PROCESS_INFORMATION, STARTUPINFOA
        }
    },
};
use crate::{
    command::MemStats, error::{print_error, MultError, MultErrorTuple}, proc::{get_all_processes, proc_exists, save_task_processes, save_usage_stats, UsageStats}, task::Files, tree::{search_tree, TreeNode}
};

use super::{cpu::win_get_cpu_usage, proc::{combine_filetime, win_get_all_processes}};

pub fn run_daemon(
    files: Files,
    command: String,
    flags: &MemStats,
    task_id: u32,
) -> Result<(), MultErrorTuple> {
    if let Ok(exe_dir) = env::current_exe() {
        let spawn_dir = Path::new(&exe_dir).parent().unwrap();
        let current_dir = match env::current_dir() {
            Ok(val) => val,
            Err(_) => home::home_dir().unwrap(),
        };
        let startup_info = STARTUPINFOA::empty();
        let mut process_info = PROCESS_INFORMATION::empty();
        unsafe {
            if CreateProcessA(
                std::mem::zeroed(),
                format!(
                    "{} {} {}",
                    spawn_dir.join("mult_spawn.exe").display().to_string(),
                    files.process_dir.display().to_string(),
                    command
                )
                .as_mut_ptr(),
                std::mem::zeroed(),
                std::mem::zeroed(),
                std::mem::zeroed(),
                CREATE_NO_WINDOW,
                std::mem::zeroed(),
                current_dir.display().to_string().as_ptr(),
                &startup_info,
                &mut process_info,
            ) == 0 {
                return Err((MultError::ExeDirNotFound, None))
            }
            // Check if job object exists already
            let mut job = OpenJobObjectA(
                0x1F001F, // JOB_OBJECT_ALL_ACCESS
                0,
                format!("mult-{}", task_id).as_ptr(),
            );
            if job.is_null() {
                job = CreateJobObjectA(std::mem::zeroed(), format!("mult-{}", task_id).as_ptr());
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
            let pid = GetProcessId(process_info.hProcess);
            let job_handle: u32 = job as u32;
            thread::spawn(move || {
                let mut cpu_time_total: FILETIME = unsafe { mem::zeroed() };
                loop {
                    // Get usage metrics
                    let process_tree = win_get_all_processes(job_handle, pid);
                    save_task_processes(&files.process_dir, &process_tree);
                    unsafe { GetSystemTimeAsFileTime(&mut cpu_time_total) };
            
                    // Sleep for measuring usage over time
                    thread::sleep(Duration::from_secs(1));
            
                    // Check for any alive processes
                    let usage_stats = Arc::new(Mutex::new(HashMap::new()));
                    let keep_running = Arc::new(Mutex::new(true));
                    search_tree(&process_tree, &|node: &TreeNode| {
                        *keep_running.lock().unwrap() = true;
                        // Set cpu usage down here
                        usage_stats.lock().unwrap().insert(
                            node.pid,
                            UsageStats {
                                cpu_usage: win_get_cpu_usage(
                                    node.pid,
                                    combine_filetime(&cpu_time_total),
                                    node.clone()
                                ) as f32,
                            },
                        );
                    });
                    if !*keep_running.lock().unwrap() {
                        break;
                    }
                    save_usage_stats(&files.process_dir, &usage_stats.lock().unwrap());
                }
            });
            WaitForSingleObject(process_info.hProcess, INFINITE);
            CloseHandle(process_info.hProcess);
            CloseHandle(process_info.hThread);
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
