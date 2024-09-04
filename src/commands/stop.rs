use std::env;

use mult_lib::args::parse_args;
use mult_lib::error::{print_success, MultErrorTuple};

use mult_lib::command::CommandManager;
use mult_lib::task::TaskManager;
#[cfg(target_os = "windows")]
use mult_lib::windows::proc::win_kill_all_processes;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let command_data = CommandManager::read_command_data(task.id)?;
        #[cfg(target_os = "windows")]
        win_kill_all_processes(command_data.pid, task_id)?;
        print_success(&format!("Process {} stopped.", task_id));
    }
    Ok(())
}
