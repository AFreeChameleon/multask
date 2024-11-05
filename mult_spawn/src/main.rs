#![cfg(target_os = "windows")]
use home::home_dir;
use mult_lib::command::{CommandData, CommandManager};
use mult_lib::error::{MultError, MultErrorTuple};
use std::ffi::{c_void, OsString};
use std::os::windows::ffi::OsStrExt;
use std::{
    collections::HashMap,
    mem,
    sync::{Arc, Mutex},
    time::Duration,
};
use std::{
    env,
    fs::File,
    io::{BufRead, BufReader, Write},
    os::windows::process::CommandExt,
    path::Path,
    process,
    process::{Command, Stdio},
    ptr, thread,
    time::{SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::Foundation::GetLastError;
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectCpuRateControlInformation, JobObjectExtendedLimitInformation, SetInformationJobObject, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION, JOBOBJECT_CPU_RATE_CONTROL_INFORMATION_0, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_CPU_RATE_CONTROL_ENABLE, JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP, JOB_OBJECT_LIMIT_PROCESS_MEMORY
};
use windows_sys::Win32::System::ProcessStatus::GetProcessImageFileNameW;

use mult_lib::{
    proc::{save_task_processes, save_usage_stats, UsageStats},
    tree::{search_tree, TreeNode},
    windows::{
        cpu::win_get_cpu_usage,
        proc::{combine_filetime, win_get_all_processes},
    },
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, FILETIME},
    System::{
        SystemInformation::GetSystemTimeAsFileTime,
        Threading::{GetCurrentProcess, GetCurrentThread},
    },
};

// Usage: mult_spawn process_dir command task_id
fn main() -> Result<(), MultErrorTuple> {
    let args: Vec<String> = env::args().collect();
    let dir_string = &args[1];
    let process_dir = Path::new(&dir_string).to_owned();
    let command = &args[2];
    let task_id = &args[3];
    let mem_limit = &args[4];
    let cpu_limit = &args[5];

    let job_name: Vec<u16> = OsString::from(format!("Global\\mult-{}", task_id))
        .encode_wide()
        .chain(Some(0))
        .collect();
    let job_handle = create_job(
        job_name.as_ptr() as *mut u16,
        mem_limit.parse().unwrap(),
        cpu_limit.parse().unwrap(),
    )?;

    let thread_handle = unsafe { GetCurrentThread() };
    let process_handle = unsafe { GetCurrentProcess() };
    unsafe { AssignProcessToJobObject(job_handle, process_handle) };
    let mut child = Command::new("cmd")
        .creation_flags(0x08000000)
        .args(&["/c", &command])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Command has failed.");

    let current_dir = match env::current_dir() {
        Ok(val) => val,
        Err(_) => home_dir().unwrap(),
    };

    let mut process_name: Vec<u16> = Vec::with_capacity(1024);
    unsafe {
        GetProcessImageFileNameW(process_handle, process_name.as_mut_ptr(), 1024);
    }
    let data = CommandData {
        command: command.to_string(),
        pid: process::id(),
        dir: current_dir.display().to_string(),
        name: String::from_utf16(&process_name).unwrap(),
        starttime: 0,
    };
    CommandManager::write_command_data(data, &process_dir);

    let stdout = child.stdout.take().expect("Failed to take stdout.");
    let stderr = child.stderr.take().expect("Failed to take stderr.");

    let mut stdout_file =
        File::create(process_dir.join("stdout.out")).expect("Could not open stdout file.");
    let mut stderr_file =
        File::create(process_dir.join("stderr.err")).expect("Could not open stderr file.");

    thread::spawn(move || {
        let reader = BufReader::new(stdout);

        for line in reader.lines() {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis();
            let formatted_line = format!("{:}|{}\n", now, line.expect("Problem reading stdout."));
            stdout_file
                .write_all(formatted_line.as_bytes())
                .expect("Problem writing to stdout.");
        }
    });

    thread::spawn(move || {
        let reader = BufReader::new(stderr);

        for line in reader.lines() {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis();
            let formatted_line = format!("{:}|{}\n", now, line.expect("Problem reading stderr."));
            stderr_file
                .write_all(formatted_line.as_bytes())
                .expect("Problem writing to stderr.");
        }
    });

    let ptr_job_handle = unsafe { job_handle.as_mut().unwrap() };
    thread::spawn(move || {
        let mut cpu_time_total: FILETIME = unsafe { mem::zeroed() };
        loop {
            // Get usage metrics
            let process_tree = win_get_all_processes(ptr_job_handle, std::process::id());
            save_task_processes(&process_dir, &process_tree);
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
                            node.clone(),
                        ) as f32,
                    },
                );
            });
            if !*keep_running.lock().unwrap() {
                break;
            }
            save_usage_stats(&process_dir, &usage_stats.lock().unwrap());
        }
    });
    child.wait().unwrap();
    unsafe {
        CloseHandle(process_handle);
        CloseHandle(thread_handle);
    }
    Ok(())
}

fn create_job(
    lp_name: *const u16,
    mem_limit: i64,
    cpu_limit: i32,
) -> Result<*mut c_void, MultErrorTuple> {
    unsafe {
        let job = CreateJobObjectW(ptr::null(), lp_name);
        if job.is_null() {
            return Err((MultError::WindowsError, Some(GetLastError().to_string())));
        }
        if mem_limit != -1 {
            let mut job_limit_info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = mem::zeroed();
            job_limit_info.BasicLimitInformation = mem::zeroed();
            job_limit_info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY;
            job_limit_info.ProcessMemoryLimit = mem_limit as usize;
            if SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                std::ptr::addr_of!(job_limit_info) as *const c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) == 0
            {
                return Err((MultError::WindowsError, Some(GetLastError().to_string())));
            }
        }
        if cpu_limit != -1 {
            let job_limit_info = JOBOBJECT_CPU_RATE_CONTROL_INFORMATION {
                ControlFlags: JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP
                    | JOB_OBJECT_CPU_RATE_CONTROL_ENABLE,
                Anonymous: JOBOBJECT_CPU_RATE_CONTROL_INFORMATION_0 {
                    CpuRate: (cpu_limit * 100) as u32,
                },
            };
            if SetInformationJobObject(
                job,
                JobObjectCpuRateControlInformation,
                std::ptr::addr_of!(job_limit_info) as *const c_void,
                std::mem::size_of::<JOBOBJECT_CPU_RATE_CONTROL_INFORMATION>() as u32,
            ) == 0
            {
                return Err((MultError::WindowsError, Some(GetLastError().to_string())));
            }
        }
        Ok(job)
    }
}
