use std::env;

use mult_lib::args::{
    get_fork_flag_values, parse_args, CPU_LIMIT_FLAG, INTERACTIVE_FLAG, MEMORY_LIMIT_FLAG,
};
use mult_lib::error::{print_info, print_success, MultErrorTuple};
use mult_lib::task::{Task, TaskManager};

const FLAGS: [(&str, bool); 3] = [
    (MEMORY_LIMIT_FLAG, true),
    (CPU_LIMIT_FLAG, true),
    (INTERACTIVE_FLAG, false),
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let flags = get_fork_flag_values(&parsed_args)?;
    let command = parsed_args.values.join(" ");
    let mut new_task_id = 0;
    let mut tasks: Vec<Task> = TaskManager::get_tasks()?;
    if let Some(last_task) = tasks.last() {
        new_task_id = last_task.id + 1;
    }
    tasks.push(Task { id: new_task_id });
    print_info("Running command...");
    let files = TaskManager::generate_task_files(new_task_id, &tasks);
    #[cfg(target_family = "unix")]
    {
        use home::home_dir;
        use mult_lib::command::CommandData;
        use mult_lib::unix::fork;
        let current_dir = match env::current_dir() {
            Ok(val) => val,
            Err(_) => home_dir().unwrap(),
        };
        fork::run_daemon(
            files,
            CommandData {
                pid: 0,
                command,
                dir: current_dir.display().to_string(),
                name: String::new(),
                starttime: 0,
            },
            flags.clone(),
        )?;
    }
    #[cfg(target_family = "windows")]
    {
        use mult_lib::windows::fork;
        fork::run_daemon(files, command, &flags, new_task_id)?;
    }

    print_success(&format!("Process {} created.", new_task_id));
    Ok(())
}
