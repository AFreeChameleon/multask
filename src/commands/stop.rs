use std::env;

use mult_lib::args::parse_args;
use mult_lib::error::{print_success, MultError, MultErrorTuple};
use sysinfo::{Pid, System};

use mult_lib::task::TaskManager;
use mult_lib::command::CommandManager;

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &[], true)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let command_data = CommandManager::read_command_data(task.id)?;
        kill_process(command_data.pid)?;
        print_success(&format!("Process {} stopped.", task_id));
    }
    Ok(())
}

pub fn kill_process(pid: u32) -> Result<(), MultErrorTuple> {
    let sys = System::new_all();
    if let Some(process) = sys.process(Pid::from_u32(pid)) {
        process.kill();
    } else {
        return Err((MultError::ProcessNotRunning, None))
    }
    Ok(())
}
