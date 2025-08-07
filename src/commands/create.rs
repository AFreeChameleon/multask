use std::env;

use mult_lib::args::parse_args;
use mult_lib::task::{Task, TaskManager};
use mult_lib::error::{print_info, print_success, MultErrorTuple};

#[cfg(target_family = "unix")]
use crate::platform_lib::linux::fork;
#[cfg(target_family = "windows")]
use crate::platform_lib::windows::fork;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    for arg in parsed_args.values.iter() {
        let mut new_task_id = 0;
        let mut tasks: Vec<Task> = TaskManager::get_tasks()?;
        if let Some(last_task) = tasks.last() {
            new_task_id = last_task.id + 1;
        }
        tasks.push(Task { id: new_task_id });
        print_info("Running command...");
        let files = TaskManager::generate_task_files(new_task_id, &tasks);

        #[cfg(target_family = "unix")]
        fork::run_daemon(files, arg.to_string())?;

        #[cfg(target_family = "windows")]
        fork::run_daemon(files, arg.to_string())?;
        print_success(&format!("Process {} created.", new_task_id));
    }
    Ok(())
}

