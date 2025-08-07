#![cfg(target_family = "unix")]
use std::{
    env, fs::File, io::{BufRead, BufReader, Write}, path::Path, process::{Command, Stdio}, thread, time::{SystemTime, UNIX_EPOCH}
};
use home::home_dir;

use mult_lib::error::{print_info, MultError, MultErrorTuple};
use mult_lib::task::Files;
use mult_lib::command::{CommandManager, CommandData};
use sysinfo::{System, Pid};

pub fn run_daemon(files: Files, command: String) -> Result<(), MultErrorTuple> {
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
    // Do daemon stuff here
    run_command(&command, &files.process_dir)?;
    Ok(())
}

fn run_command(command: &str, process_dir: &Path) -> Result<(), MultErrorTuple> {
    let mut child = Command::new("sh")
        .args(&["-c", &command])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Command has failed.");

    let current_dir = match env::current_dir() {
        Ok(val) => val,
        Err(_) => home_dir().unwrap()
    };

    let sys = System::new_all();

    let process = sys.process(Pid::from_u32(child.id()));
    if let None = process {
        return Err((MultError::ProcessNotExists, None));
    }
    let process_name = process.unwrap().name();
    let data = CommandData {
        command: command.to_string(),
        pid: child.id(),
        dir: current_dir.display().to_string(),
        name: process_name.to_string()
    };
    CommandManager::write_command_data(data, process_dir);

    let stdout = child.stdout.take().expect("Failed to take stdout.");
    let stderr = child.stderr.take().expect("Failed to take stderr.");
    
    let mut stdout_file = File::create(process_dir.join("stdout.out"))
        .expect("Could not open stdout file.");
    let mut stderr_file = File::create(process_dir.join("stderr.err"))
        .expect("Could not open stderr file.");

    thread::spawn(move || {
        let reader = BufReader::new(stdout);

        for line in reader.lines() {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis();
            let formatted_line = format!(
                "{:}|{}\n",
                now,
                line.expect("Problem reading stdout.")
            ); 
            stdout_file.write_all(formatted_line.as_bytes())
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
            let formatted_line = format!(
                "{:}|{}\n",
                now,
                line.expect("Problem reading stderr.")
            ); 
            stderr_file.write_all(formatted_line.as_bytes())
                .expect("Problem writing to stderr.");
        }
    });
    child.wait().unwrap();
    Ok(())
}
