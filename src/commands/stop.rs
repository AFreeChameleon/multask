use std::env;

use mult_lib::args::parse_args;
use mult_lib::error::{print_info, print_success, MultErrorTuple};

use mult_lib::command::CommandManager;
use mult_lib::task::TaskManager;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let command_data = CommandManager::read_command_data(task.id)?;
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
        print_success(&format!("Process {} stopped.", task_id));
    }
    Ok(())
}
