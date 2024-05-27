#![cfg(target_family = "unix")]
use std::{
    env, fs::File, io::{BufRead, BufReader, Write}, ops::Deref, path::Path, process::{Child, Command, Stdio}, thread, time::{SystemTime, UNIX_EPOCH}
};
use cgroups_rs::{Cgroup, CgroupPid};
use home::home_dir;
use libc;

use mult_lib::{error::{print_info, MultError, MultErrorTuple}, proc::{get_proc_name}};
use mult_lib::task::Files;
use mult_lib::command::{CommandManager, CommandData, MemStats};

macro_rules! spawn_logger{
    ($out:ident,$out_file:ident) => {{
        thread::spawn(move || {
            let reader = BufReader::new($out);

            for line in reader.lines() {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis();
                let formatted_line = format!(
                    "{:}|{}\n",
                    now,
                    line.expect("Problem reading stderr.")
                ); 
                $out_file.write_all(formatted_line.as_bytes())
                    .expect("Problem writing to stderr.");
            }
        });
    }};
}


pub fn run_daemon(files: Files, command: String, stats: MemStats) -> Result<(), MultErrorTuple> {
    let process_id;
    let sid;
    unsafe {
        process_id = libc::fork();
    }
    // Fork failed
    if process_id < 0 {
        return Err((MultError::ForkFailed, None))
    }
    // Parent process - need to kill it
    if process_id > 0 {
        print_info(&format!("Process id of child process {}", process_id));
        return Ok(())
    }
    unsafe {
        libc::umask(0);
        sid = libc::setsid();
    }
    if sid < 0 {
        return Err((MultError::SetSidFailed, None))
    }
    unsafe {
        libc::close(libc::STDIN_FILENO);
        libc::close(libc::STDOUT_FILENO);
        libc::close(libc::STDERR_FILENO);
    }
    let memory_limit = libc::rlimit {
        rlim_cur: stats.memory_limit as u64,
        rlim_max: stats.memory_limit as u64 * 2
    };
    unsafe {
        libc::setrlimit(libc::RLIMIT_AS, &memory_limit);
    };
    // Do daemon stuff here
    let mut child = run_command(&command, &files.process_dir, stats)?;
    child.wait().unwrap();
    Ok(())
}

fn run_command(command: &str, process_dir: &Path, stats: MemStats) -> Result<Child, MultErrorTuple> {
    let shell_path = match env::var("SHELL") {
        Ok(val) => val,
        Err(_) => return Err((MultError::OSNotSupported, None))
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
        Err(_) => home_dir().unwrap()
    };

    let child_pid = child.id();
    let proc_name = get_proc_name(child_pid)?;
    let data = CommandData {
        command: command.to_string(),
        pid: child_pid,
        dir: current_dir.display().to_string(),
        name: proc_name,
        stats
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

