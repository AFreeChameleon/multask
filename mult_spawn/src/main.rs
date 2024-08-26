#![windows_subsystem = "windows"]
use home::home_dir;
use mult_lib::command::{CommandData, CommandManager};
use mult_lib::error::{MultError, MultErrorTuple};
use windows_sys::Win32::System::JobObjects::OpenJobObjectA;
use std::{
    env,
    fs::File,
    io::{BufRead, BufReader, Write},
    os::windows::process::CommandExt,
    path::Path,
    process,
    process::{Command, Stdio},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};
use sysinfo::{Pid, System};
use std::{collections::HashMap, mem, sync::{Arc, Mutex}, time::Duration};

use mult_lib::{proc::{save_task_processes, save_usage_stats, UsageStats}, tree::{search_tree, TreeNode}, windows::{cpu::win_get_cpu_usage, proc::{combine_filetime, win_get_all_processes}}};
use windows_sys::Win32::{Foundation::{CloseHandle, FILETIME}, System::{SystemInformation::GetSystemTimeAsFileTime, Threading::{GetCurrentProcess, GetCurrentThread}}};

// Usage: mult_spawn process_dir command task_id
fn main() -> Result<(), MultErrorTuple> {
    let args: Vec<String> = env::args().collect();
    let dir_string = args[1].clone();
    let process_dir = Path::new(&dir_string).to_owned();
    let command = args[2].clone();
    let task_id = args[3].clone();
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

    let sys = System::new_all();

    let process = sys.process(Pid::from_u32(process::id()));
    if process.is_none() {
        return Err((MultError::ProcessNotExists, None));
    }
    let process_name = process.unwrap().name();
    let data = CommandData {
        command,
        pid: process::id(),
        dir: current_dir.display().to_string(),
        name: process_name.to_string(),
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

    thread::spawn(move || {
        let mut cpu_time_total: FILETIME = unsafe { mem::zeroed() };
        let job = unsafe { &mut *OpenJobObjectA(
            0x1F001F, // JOB_OBJECT_ALL_ACCESS
            0,
            format!("mult-{}", task_id).as_ptr(),
        ) };
        loop {
            // Get usage metrics
            let process_tree = win_get_all_processes(job, process::id());
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
                            node.clone()
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
    let thread = unsafe { GetCurrentThread() };
    let process = unsafe { GetCurrentProcess() };
    child.wait().unwrap();
    unsafe {
        CloseHandle(process);
        CloseHandle(thread);
    }
    Ok(())
}

