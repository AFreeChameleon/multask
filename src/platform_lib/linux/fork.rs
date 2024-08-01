#![cfg(target_family = "unix")]
use std::{
    env, fs::File, io::{BufRead, BufReader, Write}, path::Path, process::{Child, Command, Stdio}, sync::{Arc, Mutex}, thread, time::{Duration, SystemTime, UNIX_EPOCH}
};
use home::home_dir;
use libc;

use mult_lib::{error::{print_info, MultError, MultErrorTuple}, limit::{get_all_processes, split_limit_cpu}, proc::{get_proc_name, proc_exists, save_task_processes}, tree::{compress_tree, search_tree}};
use mult_lib::task::Files;
use mult_lib::command::{CommandManager, CommandData, MemStats};
use sysinfo::{RefreshKind, System};

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
    if stats.memory_limit > -1 {
        let memory_limit = libc::rlimit {
            rlim_cur: stats.memory_limit as u64,
            rlim_max: stats.memory_limit as u64
        };
        unsafe { libc::setrlimit(libc::RLIMIT_AS, &memory_limit); }
    }
    // Do daemon stuff here
    let child = run_command(&command, &files.process_dir)?;
    if stats.cpu_limit > -1 {
        // ADD IN ANOTHER THREAD TO STOP BLOCKING
        let child_id = child.id();
        thread::spawn(move || {
            split_limit_cpu(child_id as i32, stats.cpu_limit as f32);
        });
    }
    loop {
        let process_tree = get_all_processes(child.id() as usize);
        save_task_processes(&files.process_dir, &process_tree);
        let keep_running = Arc::new(Mutex::new(true));
        search_tree(&process_tree, &|pid: usize| {
            if proc_exists(pid as i32) {
                *keep_running.lock().unwrap() = true;
            }
        });
        if !*keep_running.lock().unwrap() {
            break;
        }
        thread::sleep(Duration::from_secs(1));
    }
    Ok(())
}

fn run_command(command: &str, process_dir: &Path) -> Result<Child, MultErrorTuple> {
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
        name: proc_name
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

