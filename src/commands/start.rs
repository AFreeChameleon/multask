use std::env;

use crate::task::TaskManager;
use crate::command::CommandManager;

#[cfg(target_os = "linux")]
use crate::linux;

pub fn run() -> Result<(), String> {
    let tasks = TaskManager::get_tasks();
    let task_id: u32 = TaskManager::parse_arg(env::args().nth(2)).unwrap();
    let task = TaskManager::get_task(&tasks, task_id).unwrap();
    let files = TaskManager::generate_task_files(task.id, &tasks);
    let command_data = match CommandManager::read_command_data(task.id) {
        Ok(data) => data,
        Err(message) => return Err(message)
    };
    println!("Running process with id {}...", env::args().nth(2).unwrap());
    #[cfg(target_os = "linux")]
    linux::daemonize_task(files, command_data.command);
    Ok(())
}
