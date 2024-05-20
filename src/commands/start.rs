use std::env;

use mult_lib::args::parse_args;
use mult_lib::error::{print_success, MultError, MultErrorTuple};
use mult_lib::proc::{get_proc_name};
use mult_lib::task::{TaskManager, Files};
use mult_lib::command::{CommandData, CommandManager};

#[cfg(target_family = "unix")]
use crate::platform_lib::linux::fork;

#[cfg(target_family = "windows")]
use crate::platform_lib::windows::fork;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let files = TaskManager::generate_task_files(task.id, &tasks);
        let command_data = CommandManager::read_command_data(task.id)?;
        match get_proc_name(command_data.pid) {
            Ok(val) => {
                if val == command_data.name {
                    return Err((MultError::ProcessAlreadyRunning, None))
                }
            },
            Err(_) => ()
        };
        let current_dir = env::current_dir().unwrap();
        env::set_current_dir(&command_data.dir).unwrap();
        start_process(files, command_data)?;
        env::set_current_dir(&current_dir).unwrap();
        print_success(&format!("Process {} started.", task_id));
    }
    Ok(())
}

pub fn start_process(files: Files, command_data: CommandData) -> Result<(), MultErrorTuple> {
    #[cfg(target_family = "unix")]
    fork::run_daemon(files, command_data.command, None)?;
    #[cfg(target_family = "windows")]
    fork::run_daemon(files, command_data.command)?;
    Ok(())
}
