#![cfg(target_family = "unix")]
use std::{
    env,
    fs::File,
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

use crate::task::Files;
use crate::{
    command::{CommandData, CommandManager},
    proc::ForkFlagTuple,
    unix::proc::unix_get_error_code,
};
use crate::{
    error::{print_info, MultError, MultErrorTuple},
    proc::PID,
};

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

pub fn run_daemon(
    files: Files,
    command: CommandData,
    stats: ForkFlagTuple,
) -> Result<(), MultErrorTuple> {
    let (memory_limit, cpu_limit, interactive) = stats;
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
    // Creates grandchild process to orphan it so no zombie processes are made
    if unsafe { libc::fork() } > 0 {
        unsafe { libc::_exit(0) };
    }
    close_std_handles();
    unsafe {
        libc::umask(0);
        sid = libc::setsid();
    }
    if sid < 0 {
        return Err((MultError::SetSidFailed, None));
    }
    // Do daemon stuff here
    let child = run_command(&command, &files.process_dir, interactive)?;
    if memory_limit > -1 {
        let memory_rlimit = libc::rlimit {
            rlim_cur: memory_limit as _,
            rlim_max: memory_limit as _,
        };
        #[cfg(target_os = "linux")]
        unsafe {
            libc::syscall(
                libc::SYS_prlimit64,
                child.id() as i64,
                libc::RLIMIT_AS,
                &memory_rlimit,
                std::ptr::null::<libc::rlimit>(),
            );
        }
        #[cfg(not(target_os = "linux"))]
        unsafe {
            libc::setrlimit(libc::RLIMIT_RSS, &memory_rlimit);
        }
    }
    if cpu_limit > -1 {
        let child_id = child.id();
        thread::spawn(move || {
            split_limit_cpu(child_id as PID, cpu_limit as f32);
        });
    }

    #[cfg(target_os = "freebsd")]
    {
        use crate::bsd::proc::bsd_monitor_stats;
        bsd_monitor_stats(child.id() as PID, files, stats);
    }
    #[cfg(target_os = "linux")]
    {
        use crate::linux::proc::linux_monitor_stats;
        linux_monitor_stats(child.id() as PID, files);
    }
    #[cfg(target_os = "macos")]
    {
        use crate::macos::proc::macos_monitor_stats;
        macos_monitor_stats(child.id() as PID, files, stats);
    }
    // Killing process if this wrapper fails
    unsafe { libc::kill(child.id() as _, libc::SIGINT); }
    Ok(())
}

fn close_std_handles() {
    let std_handles;
    #[cfg(target_os = "macos")]
    {
        std_handles = [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO];
    }
    #[cfg(not(target_os = "macos"))]
    {
        std_handles = [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO];
    }
    for handle in std_handles {
        unsafe {
            if libc::fcntl(handle, libc::F_GETFD) != -1 && unix_get_error_code() != libc::EBADF {
                libc::close(handle);
            }
        }
    }
}

fn run_command(
    command: &CommandData,
    process_dir: &Path,
    interactive: bool,
) -> Result<Child, MultErrorTuple> {
    let mut args = "-c";
    let shell_path = match env::var("SHELL") {
        Ok(val) => {
            if SUPPORTED_SHELLS
                .into_iter()
                .find(|shell_name| val.ends_with(shell_name))
                .is_some()
            {
                if interactive {
                    args = "-ic"
                }
                val
            } else {
                "/bin/bash".to_string()
            }
        }
        Err(_) => return Err((MultError::OSNotSupported, None)),
    };
    let mut child = Command::new(shell_path)
        .args([args, &command.command])
        .current_dir(command.dir.to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::piped())
        .spawn()
        .expect("Command has failed.");

    let child_pid = child.id() as PID;
    let data = get_command_data(
        child_pid,
        command.command.to_string(),
        command.dir.to_string(),
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
    #[cfg(target_os = "linux")]
    {
        use crate::linux::proc::linux_get_proc_name;
        use crate::linux::proc::linux_get_process_stats;
        let stats = linux_get_process_stats(pid);
        if stats.len() == 0 {
            return Err((MultError::ProcessNotExists, None));
        }
        let data = CommandData {
            pid,
            command,
            dir,
            starttime: stats[21].parse().unwrap(),
            name: linux_get_proc_name(pid)?,
        };
        return Ok(data);
    }
    #[cfg(target_os = "freebsd")]
    {
        use crate::bsd::proc::{bsd_get_proc_name, bsd_get_process_stats};
        let proc_stats = bsd_get_process_stats(pid);
        if proc_stats.is_none() {
            return Err((MultError::ProcessNotExists, None));
        }
        let data = CommandData {
            pid,
            command,
            dir,
            starttime: proc_stats.unwrap().ki_start.tv_sec as u64,
            name: bsd_get_proc_name(proc_stats),
        };
        return Ok(data);
    }
    #[cfg(target_os = "macos")]
    {
        use crate::macos::proc::macos_get_all_process_stats;
        use crate::unix::proc::unix_convert_c_string;
        let all_stats = macos_get_all_process_stats(pid);
        if all_stats.is_none() {
            return Err((MultError::ProcessNotExists, None));
        }
        let data = CommandData {
            pid,
            command,
            dir,
            starttime: all_stats.unwrap().pbsd.pbi_start_tvsec,
            name: unix_convert_c_string(all_stats.unwrap().pbsd.pbi_name.iter()),
        };
        return Ok(data);
    }
}

fn split_limit_cpu(pid: PID, limit: f32) {
    #[cfg(target_os = "linux")]
    {
        use crate::linux::cpu::linux_split_limit_cpu;
        linux_split_limit_cpu(pid, limit);
    }
    #[cfg(target_os = "freebsd")]
    {
        use crate::bsd::cpu::bsd_split_limit_cpu;
        bsd_split_limit_cpu(pid, limit);
    }
    #[cfg(target_os = "macos")]
    {
        use crate::macos::cpu::macos_split_limit_cpu;
        macos_split_limit_cpu(pid, limit);
    }
}
