use mult_lib::args::{parse_args, ParsedArgs};
use mult_lib::colors::{color_string, OK_GREEN};
use mult_lib::proc::{
    get_all_processes, get_proc_comm, get_process_memory, get_process_runtime, get_process_stats,
    get_readable_runtime, proc_exists, read_usage_stats,
};
use mult_lib::tree::compress_tree;
use prettytable::Table;
use std::{env, thread, time::Duration};

use mult_lib::command::CommandManager;
use mult_lib::error::{MultError, MultErrorTuple};
use mult_lib::table::{MainHeaders, ProcessHeaders, TableManager};
use mult_lib::task::{Task, TaskManager};

const WATCH_FLAG: &str = "-w";
const LIST_CHILDREN_FLAG: &str = "-a";
const FLAGS: [(&str, bool); 2] = [(WATCH_FLAG, false), (LIST_CHILDREN_FLAG, false)];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, false)?;
    let mut table = TableManager {
        ascii_table: Table::new(),
        table_data: Vec::new(),
    };
    table.create_headers();
    setup_table(&mut table, &parsed_args)?;
    if parsed_args.flags.contains(&WATCH_FLAG.to_string()) {
        if cfg!(target_family = "windows") {
            return Err((MultError::WindowsNotSupported, Some("-w".to_string())));
        }
        listen(&parsed_args)?;
    } else {
        table.print();
    }

    Ok(())
}

fn listen(parsed_args: &ParsedArgs) -> Result<(), MultErrorTuple> {
    let mut table = TableManager {
        ascii_table: Table::new(),
        table_data: Vec::new(),
    };
    table.create_headers();
    setup_table(&mut table, parsed_args)?;
    let mut height = table.print();
    let mut terminal = term::stdout().unwrap();
    loop {
        thread::sleep(Duration::from_secs(1));
        table = TableManager {
            ascii_table: Table::new(),
            table_data: Vec::new(),
        };
        table.create_headers();
        setup_table(&mut table, parsed_args)?;
        for _ in 0..height {
            terminal.cursor_up().unwrap();
            terminal.delete_line().unwrap();
        }
        height = table.print();
    }
}

pub fn setup_table(
    table: &mut TableManager,
    parsed_args: &ParsedArgs,
) -> Result<(), MultErrorTuple> {
    let tasks: Vec<Task> = TaskManager::get_tasks()?;
    for task in tasks.iter() {
        let command = match CommandManager::read_command_data(task.id) {
            Ok(result) => result,
            Err(err) => return Err(err),
        };
        let mut main_headers = MainHeaders {
            id: task.id,
            command: command.command.clone(),
        };
        // Get memory stats
        let process_headers_opt = get_process_headers(command.pid as usize, command.starttime, &task, true);
        if process_headers_opt.is_none() {
            continue;
        }
        let mut process_headers = process_headers_opt.unwrap();
        let process_tree = get_all_processes(command.pid as usize);

        let mut all_processes = vec![];
        compress_tree(&process_tree, &mut all_processes);
        if all_processes.len() > 1 {
            if parsed_args.flags.contains(&LIST_CHILDREN_FLAG.to_string()) {
                for child_process_id in all_processes.iter() {
                    if *child_process_id as u32 == command.pid {
                        continue;
                    }
                    if !proc_exists(*child_process_id as i32) {
                        continue;
                    }
                    if let Some(child_process_headers) = get_process_headers(command.pid as usize, command.starttime, &task, false) {
                        main_headers.command.push_str(
                            &format!("\n {}", get_proc_comm(*child_process_id as u32)?)
                        );
                        process_headers.pid.push_str(
                            &format!("\n{}", child_process_headers.pid)
                        );
                        process_headers.memory.push_str(
                            &format!("\n{}", child_process_headers.memory)
                        );
                        process_headers.cpu.push_str(
                            &child_process_headers.cpu
                        );
                        process_headers.runtime.push_str(
                            &format!("\n{}", child_process_headers.runtime)
                        );
                        process_headers.status.push_str(
                            &format!("\n{}", color_string(OK_GREEN, "Running"))
                        );
                    }
                }
            } else {
                main_headers
                    .command
                    .push_str(&format!("\n + {} more processes", all_processes.len() - 1));
            }
        }

        table.insert_row(main_headers, Some(process_headers));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn linux_get_process_headers(pid: usize, starttime: u32, task: &Task, is_main_process: bool) -> Option<ProcessHeaders> {
    let proc_stats = get_process_stats(pid as usize);
    if is_main_process && (proc_stats.len() == 0 || starttime != proc_stats[21].parse().unwrap()) {
        return None;
    }
    let mut cpu_usage = 0.0;
    let usage_stats = match read_usage_stats(task.id) {
        Ok(val) => val,
        Err(_) => return None
    };
    if let Some(stats) = usage_stats.get(&(pid as usize)) {
        cpu_usage = (stats.cpu_usage * 100.0).round() / 100.0;
    }
    // Get memory stats
    Some(ProcessHeaders {
        pid: pid.to_string(),
        memory: get_process_memory(&(pid as usize)),
        cpu: format!("{}%", cpu_usage),
        runtime: get_readable_runtime(
            get_process_runtime(proc_stats[21].parse().unwrap()) as u64
        ),
        status: color_string(OK_GREEN, "Running").to_string()
    })
}

fn get_process_headers(pid: usize, starttime: u32, task: &Task, is_main_process: bool) -> Option<ProcessHeaders> {
    #[cfg(target_os = "linux")]
    return linux_get_process_headers(pid, starttime, task, is_main_process);
    None
}
