use std::env;

use mult_lib::args::{parse_args, ParsedArgs};
use mult_lib::proc::{create_cgroup, create_task_cgroup, create_user_cgroup, CGroup};
use mult_lib::task::{Task, TaskManager};
use mult_lib::error::{print_info, print_success, MultError, MultErrorTuple};

#[cfg(target_family = "unix")]
use crate::platform_lib::linux::fork;
#[cfg(target_family = "windows")]
use crate::platform_lib::windows::fork;

const CPU_SHARES_FLAG: &str = "--cpu-shares";
const MEMORY_LIMIT_FLAG: &str = "--memory-limit";
const FLAGS: [(&str, bool); 2] = [
    (CPU_SHARES_FLAG, true),
    (MEMORY_LIMIT_FLAG, true)
];

struct CreateFlags {
    cpu_shares: u64,
    memory_limit: i64
}

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    let flags: CreateFlags = get_flag_values(&parsed_args)?;
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
            let mut cg = CGroup {
                task_id: new_task_id,
                memory_limit: flags.memory_limit,
                cpu_shares: flags.cpu_shares,
                path: None
            };
            cg.add_user()?;

            //let cg = create_cgroup(new_task_id, flags.cpu_shares, flags.memory_limit);
            fork::run_daemon(files, arg.to_string(), Some(cg))?;
        }

        #[cfg(target_family = "windows")]
        fork::run_daemon(files, arg.to_string())?;
        print_success(&format!("Process {} created.", new_task_id));
    }
    Ok(())
}

fn get_flag_values(parsed_args: &ParsedArgs) -> Result<CreateFlags, MultErrorTuple> {
    let mut cpu_shares: u64 = 100;
    let mut memory_limit: i64 = 1024 * 1024;
    if let Some(cpu_shares_flag) = parsed_args.value_flags.clone().into_iter().find(|(flag, _)| {
        flag == CPU_SHARES_FLAG
    }) {
        if cpu_shares_flag.1.is_some() {
            cpu_shares = match cpu_shares_flag.1.unwrap().parse::<u64>() {
                Err(_) => return Err((MultError::InvalidArgument, Some(CPU_SHARES_FLAG.to_string()))),
                Ok(val) => val
            };
        }
    }
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
    Ok(CreateFlags {
        cpu_shares,
        memory_limit
    })
}
