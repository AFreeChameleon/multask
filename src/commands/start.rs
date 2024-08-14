use std::env;

use mult_lib::args::{parse_args, ParsedArgs};
use mult_lib::error::{print_success, MultError, MultErrorTuple};
use mult_lib::proc::proc_exists;
use mult_lib::task::TaskManager;
use mult_lib::command::{CommandManager, MemStats};

#[cfg(target_family = "unix")]
use crate::platform_lib::linux::fork;

#[cfg(target_family = "windows")]
use crate::platform_lib::windows::fork;

const MEMORY_LIMIT_FLAG: &str = "-m";
const CPU_LIMIT_FLAG: &str = "-c";
const FLAGS: [(&str, bool); 2] = [
    (MEMORY_LIMIT_FLAG, true),
    (CPU_LIMIT_FLAG, true)
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let flags: MemStats = get_flag_values(&parsed_args)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let files = TaskManager::generate_task_files(task.id, &tasks);
        let command_data = CommandManager::read_command_data(task.id)?;
        if proc_exists(command_data.pid as i32) {
            return Err((MultError::ProcessAlreadyRunning, None))
        }
        let current_dir = env::current_dir().unwrap();
        env::set_current_dir(&command_data.dir).unwrap();

        #[cfg(target_family = "unix")]
        fork::run_daemon(files, command_data.command, flags.clone())?;
        #[cfg(target_family = "windows")]
        fork::run_daemon(files, command_data.command)?;

        env::set_current_dir(&current_dir).unwrap();
        print_success(&format!("Process {} started.", task_id));
    }
    Ok(())
}

fn get_flag_values(parsed_args: &ParsedArgs) -> Result<MemStats, MultErrorTuple> {
    let mut memory_limit: i64 = -1;
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
    let mut cpu_limit: i32 = -1;
    if let Some(cpu_limit_flag) = parsed_args.value_flags.clone().into_iter().find(|(flag, _)| {
        flag == CPU_LIMIT_FLAG
    }) {
        if cpu_limit_flag.1.is_some() {
            cpu_limit = match cpu_limit_flag.1.unwrap().parse::<i32>() {
                Err(_) => return Err((MultError::InvalidArgument, Some(CPU_LIMIT_FLAG.to_string()))),
                Ok(val) => val
            };
        }
    }
    Ok(MemStats {
        memory_limit,
        cpu_limit
    })
}
