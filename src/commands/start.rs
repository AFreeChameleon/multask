use std::env;

use mult_lib::args::{
    get_fork_flag_values, parse_args, CPU_LIMIT_FLAG, INTERACTIVE_FLAG, MEMORY_LIMIT_FLAG,
};
use mult_lib::command::CommandManager;
use mult_lib::error::{print_success, MultError, MultErrorTuple};
use mult_lib::proc::proc_exists;
use mult_lib::task::TaskManager;

const FLAGS: [(&str, bool); 3] = [
    (MEMORY_LIMIT_FLAG, true),
    (CPU_LIMIT_FLAG, true),
    (INTERACTIVE_FLAG, false),
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let flags = get_fork_flag_values(&parsed_args)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let files = TaskManager::generate_task_files(task.id, &tasks);
        let command_data = CommandManager::read_command_data(task.id)?;
        if proc_exists(command_data.pid) {
            return Err((MultError::ProcessAlreadyRunning, None));
        }
        #[cfg(target_family = "unix")]
        {
            use mult_lib::unix::fork;
            fork::run_daemon(files, command_data, flags.clone())?;
        }
        #[cfg(target_family = "windows")]
        {
            use mult_lib::windows::fork;
            fork::run_daemon(files, command_data.command, &flags, task_id)?;
        }

        print_success(&format!("Process {} started.", task_id));
    }
    Ok(())
}
