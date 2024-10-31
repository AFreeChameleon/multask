use std::{env, fs, path::Path};

use mult_lib::args::parse_args;
use mult_lib::command::CommandManager;
use mult_lib::error::{print_info, print_success, MultError, MultErrorTuple};
use mult_lib::task::TaskManager;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    let tasks = TaskManager::get_tasks()?;
    let mut new_tasks = tasks.clone();
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        if let Ok(command_data) = CommandManager::read_command_data(task.id) {
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
        }
        new_tasks = new_tasks.into_iter().filter(|t| t.id != task_id).collect();
        let process_dir = Path::new(&home::home_dir().unwrap())
            .join(".multi-tasker")
            .join("processes")
            .join(task_id.to_string());
        match fs::remove_dir_all(process_dir) {
            Ok(()) => {}
            Err(_) => return Err((MultError::ProcessDirNotExist, None)),
        };
        print_success(&format!("Process {} deleted.", task_id));
    }
    TaskManager::write_tasks_file(&new_tasks);
    println!("Processes saved.");
    Ok(())
}
