use std::env;

use mult_lib::args::{
    get_fork_flag_values, parse_args, CPU_LIMIT_FLAG, INTERACTIVE_FLAG, MEMORY_LIMIT_FLAG,
};
use mult_lib::command::CommandManager;
use mult_lib::error::{print_info, print_success, MultErrorTuple};
use mult_lib::task::TaskManager;

#[cfg(target_family = "unix")]
use mult_lib::unix::fork;
#[cfg(target_family = "windows")]
use mult_lib::windows::fork;

const FLAGS: [(&str, bool); 3] = [
    (MEMORY_LIMIT_FLAG, true),
    (CPU_LIMIT_FLAG, true),
    (INTERACTIVE_FLAG, false),
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let tasks = TaskManager::get_tasks()?;
    let flags = get_fork_flag_values(&parsed_args)?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let command_data = CommandManager::read_command_data(task.id)?;
        print_info("Killing process...");
        #[cfg(target_os = "windows")]
        {
            use mult_lib::windows::proc::win_kill_all_processes;
            match win_kill_all_processes(command_data.pid, task_id) {
                Ok(_) => (),
                Err(_) => print_info(&format!("Process {} is not running.", task_id)),
            }
        }
        #[cfg(target_os = "linux")]
        {
            use mult_lib::linux::proc::linux_kill_all_processes;
            match linux_kill_all_processes(command_data.pid as i32) {
                Ok(_) => (),
                Err(_) => print_info(&format!("Process {} is not running.", task_id)),
            }
        }
        #[cfg(target_os = "freebsd")]
        {
            use mult_lib::bsd::proc::bsd_kill_all_processes;
            match bsd_kill_all_processes(command_data.pid as i32) {
                Ok(_) => (),
                Err(_) => print_info(&format!("Process {} is not running.", task_id)),
            }
        }
        #[cfg(target_os = "macos")]
        {
            use mult_lib::macos::proc::macos_kill_all_processes;
            match macos_kill_all_processes(command_data.pid as i32) {
                Ok(_) => (),
                Err(_) => print_info(&format!("Process {} is not running.", task_id)),
            }
        }
        let files = TaskManager::generate_task_files(task.id, &tasks);
        print_info("Restarting process...");

        #[cfg(target_family = "unix")]
        fork::run_daemon(files, command_data, flags.clone())?;
        #[cfg(target_family = "windows")]
        fork::run_daemon(files, command_data.command, &flags, task_id)?;

        print_success(&format!("Process {} restarted.", task_id));
    }
    Ok(())
}
