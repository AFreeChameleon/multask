use std::env;

use mult_lib::args::{parse_args, parse_string_to_bytes, ParsedArgs};
use mult_lib::error::{print_info, print_success, MultError, MultErrorTuple};
use mult_lib::proc::ForkFlagTuple;
use mult_lib::task::{Task, TaskManager};

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
    for arg in parsed_args.values.iter() {
        let mut new_task_id = 0;
        let mut tasks: Vec<Task> = TaskManager::get_tasks()?;
        if let Some(last_task) = tasks.last() {
            new_task_id = last_task.id + 1;
        }
        tasks.push(Task { id: new_task_id });
        print_info("Running command...");
        let files = TaskManager::generate_task_files(new_task_id, &tasks);
        #[cfg(target_family = "unix")] {
            use mult_lib::unix::fork;
            fork::run_daemon(files, arg.to_string(), flags.clone())?;
        }
        #[cfg(target_family = "windows")] {
            use mult_lib::windows::fork;
            fork::run_daemon(files, arg.to_string(), &flags, new_task_id)?;
        }

        print_success(&format!("Process {} created.", new_task_id));
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
