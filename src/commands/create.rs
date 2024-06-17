use std::env;

use mult_lib::args::{parse_args, ParsedArgs};
use mult_lib::command::MemStats;
use mult_lib::task::{Task, TaskManager};
use mult_lib::error::{print_info, print_success, MultError, MultErrorTuple};

#[cfg(target_family = "unix")]
use crate::platform_lib::linux::fork;
#[cfg(target_family = "windows")]
use crate::platform_lib::windows::fork;

const MEMORY_LIMIT_FLAG: &str = "-m";
const FLAGS: [(&str, bool); 1] = [
    (MEMORY_LIMIT_FLAG, true)
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let flags: MemStats = get_flag_values(&parsed_args)?;
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
        fork::run_daemon(files, arg.to_string(), flags.clone())?;

        #[cfg(target_family = "windows")]
        fork::run_daemon(files, arg.to_string())?;
        print_success(&format!("Process {} created.", new_task_id));
    }
    Ok(())
}

fn get_flag_values(parsed_args: &ParsedArgs) -> Result<MemStats, MultErrorTuple> {
    let mut memory_limit: i64 = 1024 * 1024;
    if let Some(memory_limit_flag) = parsed_args.value_flags.clone().into_iter().find(|(flag, _)| {
        flag == MEMORY_LIMIT_FLAG
    }) {
        if memory_limit_flag.1.is_some() {
            memory_limit = match memory_limit_flag.1.unwrap().parse::<i64>() {
                Err(_) => return Err((MultError::InvalidArgument, Some(MEMORY_LIMIT_FLAG.to_string()))),
                Ok(val) => val
            };
        }
    }
    Ok(MemStats {
        memory_limit
    })
}
