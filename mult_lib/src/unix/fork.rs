#![cfg(target_family = "unix")]
use home::home_dir;
use libc;
use std::{
    collections::HashMap,
    env,
    fs::File,
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
    mem
};

use crate::{command::{CommandData, CommandManager, MemStats}};
use crate::task::Files;
use crate::{
    error::{print_info, MultError, MultErrorTuple},
    proc::{
        save_task_processes, save_usage_stats, UsageStats, PID
    },
    tree::{search_tree, TreeNode},
};

use crate::unix::proc::unix_proc_exists;

macro_rules! spawn_logger {
    ($out:ident,$out_file:ident) => {{
        thread::spawn(move || {
            let reader = BufReader::new($out);

            for line in reader.lines() {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis();
                let formatted_line =
                    format!("{:}|{}\n", now, line.expect("Problem reading stderr."));
                $out_file
                    .write_all(formatted_line.as_bytes())
                    .expect("Problem writing to stderr.");
            }
        });
    }};
}

const SUPPORTED_SHELLS: [&str; 3] = ["/sh", "/bash", "/zsh"];

pub fn run_daemon(files: Files, command: String, stats: MemStats) -> Result<(), MultErrorTuple> {
    let process_id;
    let sid;
    unsafe {
        process_id = libc::fork();
    }
    // Fork failed
    if process_id < 0 {
        return Err((MultError::ForkFailed, None));
    }
    // Parent process - need to kill it
    if process_id > 0 {
        print_info(&format!("Process id of child process {}", process_id));
        return Ok(());
    }
    unsafe {
        libc::umask(0);
        sid = libc::setsid();
    }
    if sid < 0 {
        return Err((MultError::SetSidFailed, None));
    }
    unsafe {
        libc::close(libc::STDIN_FILENO);
        libc::close(libc::STDOUT_FILENO);
        libc::close(libc::STDERR_FILENO);
    }
    if stats.memory_limit > -1 {
        let memory_limit = libc::rlimit {
            rlim_cur: stats.memory_limit as _,
            rlim_max: stats.memory_limit as _,
        };
        unsafe {
            libc::setrlimit(libc::RLIMIT_AS, &memory_limit);
        }
    }
    // Do daemon stuff here
    let child = run_command(&command, &files.process_dir)?;
    if stats.cpu_limit > -1 {
        let child_id = child.id();
        thread::spawn(move || {
            split_limit_cpu(child_id as PID, stats.cpu_limit as f32);
        });
    }
    let mut cpu_time_total;
    loop {
        // Get usage metrics
        let process_tree = get_all_processes(child.id() as PID);
        save_task_processes(&files.process_dir, &process_tree);
        cpu_time_total = get_cpu_time_total(get_cpu_stats());

        // Sleep for measuring usage over time
        thread::sleep(Duration::from_secs(1));

        // Check for any alive processes
        let usage_stats = Arc::new(Mutex::new(HashMap::new()));
        let keep_running = Arc::new(Mutex::new(true));
        search_tree(&process_tree, &|node: &TreeNode| {
            if unix_proc_exists(node.pid) {
                *keep_running.lock().unwrap() = true;
                // Set cpu usage down here
                usage_stats.lock().unwrap().insert(
                    node.pid,
                    UsageStats {
                        cpu_usage: get_cpu_usage(node.pid, node.clone(), cpu_time_total),
                    },
                );
            }
        });
        if !*keep_running.lock().unwrap() {
            break;
        }
        save_usage_stats(&files.process_dir, &usage_stats.lock().unwrap());
    }
    Ok(())
}

fn run_command(command: &str, process_dir: &Path) -> Result<Child, MultErrorTuple> {
    let shell_path = match env::var("SHELL") {
        Ok(val) => {
            if SUPPORTED_SHELLS
                .into_iter()
                .find(|shell_name| val.ends_with(shell_name))
                .is_some()
            {
                val
            } else {
                "/bin/sh".to_string()
            }
        }
        Err(_) => return Err((MultError::OSNotSupported, None)),
    };
    let mut child = Command::new(shell_path)
        .args(["-c", &command])
        .env("FORCE_COLOR", "true")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Command has failed.");

    let current_dir = match env::current_dir() {
        Ok(val) => val,
        Err(_) => home_dir().unwrap(),
    };

    let child_pid = child.id() as PID;
    let data = get_command_data(
        child_pid,
        command.to_string(),
        current_dir.display().to_string()
    );
    CommandManager::write_command_data(data?, process_dir);

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let mut stdout_file = File::create(process_dir.join("stdout.out")).unwrap();
    let mut stderr_file = File::create(process_dir.join("stderr.err")).unwrap();

    spawn_logger!(stderr, stderr_file);
    spawn_logger!(stdout, stdout_file);
    Ok(child)
}

fn get_command_data(pid: PID, command: String, dir: String) -> Result<CommandData, MultErrorTuple> {
    #[cfg(target_os = "freebsd")] {
        use crate::bsd::proc::bsd_get_process_stats;
        let proc_stats = bsd_get_process_stats(pid);
        if proc_stats.is_none() {
            return Err((MultError::ProcessNotExists, None));
        }
        let data = CommandData {
            pid: pid,
            command,
            dir,
            starttime: proc_stats.unwrap().ki_runtime,
            name: String::from_utf8(proc_stats.unwrap().ki_comm.iter().map(|&c| c as u8).collect()).unwrap(),
        };
        return Ok(data);
    }
}

fn get_process_starttime(pid: PID) -> Result<u64, MultErrorTuple> {
    #[cfg(target_os = "linux")] {
        use crate::linux::proc::linux_get_process_stats;
        return linux_get_process_stats(pid);
    }
    #[cfg(target_os = "freebsd")] {
        use crate::bsd::proc::bsd_get_process_stats;
        let proc_stats = bsd_get_process_stats(pid as PID);
        if proc_stats.is_none() {
            return Err((MultError::ProcessNotExists, None));
        }
        return Ok(proc_stats.unwrap().ki_start.tv_sec as u64);
    }

    return Ok(0);
}

fn get_all_processes(pid: PID) -> TreeNode {
    #[cfg(target_os = "linux")] {
        use crate::linux::proc::linux_get_all_processes;
        return linux_get_all_processes(pid);
    }
    #[cfg(target_os = "freebsd")] {
        use crate::bsd::proc::bsd_get_all_processes;
        return bsd_get_all_processes(pid);
    }
}

fn get_cpu_time_total(cpu_stats: Vec<String>) -> u32 {
    #[cfg(target_os = "linux")] {
        use crate::linux::cpu::linux_get_cpu_time_total;
        return linux_get_cpu_time_total(cpu_stats);
    }
    #[cfg(target_os = "freebsd")]
    return 0;
}

fn get_cpu_stats() -> Vec<String> {
    #[cfg(target_os = "linux")] {
        use crate::linux::proc::linux_get_cpu_stats;
        return linux_get_cpu_stats();
    }
    #[cfg(target_os = "freebsd")]
    return Vec::new();
}

fn get_cpu_usage(pid: PID, node: TreeNode, old_total_time: u32) -> f32 {
    #[cfg(target_os = "linux")] {
        use crate::linux::cpu::linux_get_cpu_usage;
        return linux_get_cpu_usage(pid, node, old_total_time);
    }
    #[cfg(target_os = "freebsd")] {
        use crate::bsd::cpu::bsd_get_cpu_usage;
        use crate::bsd::proc::bsd_get_process_stats;
        let stats = bsd_get_process_stats(pid);
        if stats.is_none() {
            return 0.0;
        }
        return bsd_get_cpu_usage(stats.unwrap());
    }
}

fn split_limit_cpu(pid: PID, limit: f32) {
    #[cfg(target_os = "linux")] {
        use crate::linux::cpu::linux_split_limit_cpu;
        linux_split_limit_cpu(pid, limit);
    }
    #[cfg(target_os = "freebsd")] {
        use crate::bsd::cpu::bsd_split_limit_cpu;
        bsd_split_limit_cpu(pid, limit);
    }
}

fn get_proc_name(pid: PID) -> Result<String, MultErrorTuple> {
    #[cfg(target_os = "linux")] {
        use crate::linux::proc::linux_get_proc_name;
        return linux_get_proc_name(pid);
    }
    #[cfg(target_os = "freebsd")]
    return Ok(String::new());
}

