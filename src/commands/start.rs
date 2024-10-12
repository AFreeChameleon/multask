use std::env;

use mult_lib::args::{parse_args, parse_string_to_bytes, ParsedArgs};
use mult_lib::command::CommandManager;
use mult_lib::error::{print_success, MultError, MultErrorTuple};
use mult_lib::proc::{proc_exists, ForkFlagTuple};
use mult_lib::task::TaskManager;

const MEMORY_LIMIT_FLAG: &str = "-m";
const CPU_LIMIT_FLAG: &str = "-c";
const INTERACTIVE_FLAG: &str = "-i";
const FLAGS: [(&str, bool); 3] = [
    (MEMORY_LIMIT_FLAG, true),
    (CPU_LIMIT_FLAG, true),
    (INTERACTIVE_FLAG, false)
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let flags = get_flag_values(&parsed_args)?;
    let tasks = TaskManager::get_tasks()?;
    for arg in parsed_args.values.iter() {
        let task_id: u32 = TaskManager::parse_arg(Some(arg.to_string()))?;
        let task = TaskManager::get_task(&tasks, task_id)?;
        let files = TaskManager::generate_task_files(task.id, &tasks);
        let command_data = CommandManager::read_command_data(task.id)?;
        if proc_exists(command_data.pid) {
            return Err((MultError::ProcessAlreadyRunning, None));
        }
        let current_dir = env::current_dir().unwrap();
        env::set_current_dir(&command_data.dir).unwrap();

        #[cfg(target_family = "unix")] {
            use mult_lib::unix::fork;
            fork::run_daemon(files, command_data.command, flags.clone())?;
        }
        #[cfg(target_family = "windows")] {
            use mult_lib::windows::fork;
            fork::run_daemon(files, command_data.command, &flags, task_id)?;
        }

        env::set_current_dir(&current_dir).unwrap();
        print_success(&format!("Process {} started.", task_id));
    }
    Ok(())
}

fn get_flag_values(parsed_args: &ParsedArgs) -> Result<ForkFlagTuple, MultErrorTuple> {
    let mut memory_limit: i64 = -1;
    if let Some(memory_limit_flag) = parsed_args
        .value_flags
        .clone()
        .into_iter()
        .find(|(flag, _)| flag == MEMORY_LIMIT_FLAG)
    {
        if memory_limit_flag.1.is_some() {
            memory_limit = match parse_string_to_bytes(memory_limit_flag.1.unwrap()) {
                None => {
                    return Err((
                        MultError::InvalidArgument,
                        Some(
                            format!(
                                "{} value must have a valid format (B, kB, mB, gB) at the end",
                                MEMORY_LIMIT_FLAG.to_string()
                            )
                        ),
                    ))
                }
                Some(val) => val,
            };
            if memory_limit < 1 {
                return Err((MultError::InvalidArgument, Some(
                    format!("{} value must be over 1", CPU_LIMIT_FLAG.to_string())
                )));
            }
        }
    }
    let mut cpu_limit: i32 = -1;
    if let Some(cpu_limit_flag) = parsed_args
        .value_flags
        .clone()
        .into_iter()
        .find(|(flag, _)| flag == CPU_LIMIT_FLAG)
    {
        if cpu_limit_flag.1.is_some() {
            cpu_limit = match cpu_limit_flag.1.unwrap().parse::<i32>() {
                Err(_) => {
                    return Err((MultError::InvalidArgument, Some(CPU_LIMIT_FLAG.to_string())))
                }
                Ok(val) => val,
            };
            if cpu_limit > 100 || cpu_limit < 1 {
                return Err((MultError::InvalidArgument, Some(
                    format!("{} valid values are between 1 and 100", CPU_LIMIT_FLAG.to_string())
                )));
            }
        }
    }
    let interactive = parsed_args.flags.contains(&INTERACTIVE_FLAG.to_owned());
    Ok((
        memory_limit,
        cpu_limit,
        interactive
    ))
}
