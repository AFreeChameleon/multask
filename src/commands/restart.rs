use std::env;

use mult_lib::error::{print_info, print_success, MultErrorTuple};
use mult_lib::proc::kill_all_processes;
use mult_lib::task::TaskManager;
use mult_lib::command::CommandManager;
use mult_lib::args::parse_args;

use crate::platform_lib::linux::fork;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let command_data = CommandManager::read_command_data(task.id)?;
        print_info("Killing process...");
        kill_all_processes(command_data.pid)?;
        let files = TaskManager::generate_task_files(task.id, &tasks);
        print_info("Restarting process...");

        #[cfg(target_family = "unix")]
        fork::run_daemon(files, command_data.command, command_data.stats)?;
        #[cfg(target_family = "windows")]
        fork::run_daemon(files, command_data.command)?;

        print_success(&format!("Process {} restarted.", task_id));
    }
    Ok(())
}

