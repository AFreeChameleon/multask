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
};

use crate::{command::{CommandData, CommandManager, MemStats}, linux::proc::{linux_get_proc_name, linux_get_process_stats}};
use crate::task::Files;
use crate::{
    error::{print_info, MultError, MultErrorTuple},
    linux::proc::linux_get_all_processes,
    proc::{
        proc_exists,
        save_task_processes, save_usage_stats, UsageStats,
    },
    tree::{search_tree, TreeNode},
};

use super::{cpu::{linux_get_cpu_time_total, linux_get_cpu_usage, linux_split_limit_cpu}, proc::{linux_get_cpu_stats, linux_proc_exists}};

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
            rlim_cur: stats.memory_limit as u64,
            rlim_max: stats.memory_limit as u64,
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
            linux_split_limit_cpu(child_id as i32, stats.cpu_limit as f32);
        });
    }
    let mut cpu_time_total;
    loop {
        // Get usage metrics
        let process_tree = linux_get_all_processes(child.id() as usize);
        save_task_processes(&files.process_dir, &process_tree);
        cpu_time_total = linux_get_cpu_time_total(linux_get_cpu_stats());

        // Sleep for measuring usage over time
        thread::sleep(Duration::from_secs(1));

        // Check for any alive processes
        let usage_stats = Arc::new(Mutex::new(HashMap::new()));
        let keep_running = Arc::new(Mutex::new(true));
        search_tree(&process_tree, &|node: &TreeNode| {
            if linux_proc_exists(node.pid as i32) {
                *keep_running.lock().unwrap() = true;
                // Set cpu usage down here
                usage_stats.lock().unwrap().insert(
                    node.pid,
                    UsageStats {
                        cpu_usage: linux_get_cpu_usage(node.pid, node.clone(), cpu_time_total),
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
                "/bin/bash".to_string()
            }
        }
        Err(_) => return Err((MultError::OSNotSupported, None)),
    };
    let mut child = Command::new(shell_path)
        .args(["-ic", &command])
        .env("FORCE_COLOR", "true")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Command has failed.");

    let current_dir = match env::current_dir() {
        Ok(val) => val,
        Err(_) => home_dir().unwrap(),
    };

    let child_pid = child.id();
    let proc_name = linux_get_proc_name(child_pid)?;
    let proc_stats = linux_get_process_stats(child_pid as usize);
    let data = CommandData {
        command: command.to_string(),
        pid: child_pid,
        dir: current_dir.display().to_string(),
        name: proc_name,
        starttime: proc_stats[21].parse().unwrap(),
    };
    CommandManager::write_command_data(data, process_dir);

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let mut stdout_file = File::create(process_dir.join("stdout.out")).unwrap();
    let mut stderr_file = File::create(process_dir.join("stderr.err")).unwrap();

    spawn_logger!(stderr, stderr_file);
    spawn_logger!(stdout, stdout_file);
    Ok(child)
}
