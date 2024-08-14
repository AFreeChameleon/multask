use std::{thread, time::Duration, env};
use mult_lib::args::{parse_args, ParsedArgs};
use mult_lib::colors::{color_string, OK_GREEN};
use mult_lib::proc::{get_all_processes, get_proc_comm, get_proc_name, get_process_memory, get_process_runtime, get_process_starttime, get_process_stats, read_usage_stats};
use mult_lib::tree::compress_tree;
use prettytable::Table;
use sysinfo::{System, Pid};

use mult_lib::error::{MultError, MultErrorTuple};
use mult_lib::table::{format_bytes, MainHeaders, ProcessHeaders, TableManager};
use mult_lib::task::{Task, TaskManager};
use mult_lib::command::CommandManager;

const WATCH_FLAG: &str = "-w";
const LIST_CHILDREN_FLAG: &str = "-a";
const FLAGS: [(&str, bool); 2] = [
    (WATCH_FLAG, false),
    (LIST_CHILDREN_FLAG, false)
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, false)?;
    let mut table = TableManager {
        ascii_table: Table::new(),
        table_data: Vec::new()
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
        table_data: Vec::new()
    };
    table.create_headers();
    setup_table(&mut table, parsed_args)?;
    let mut height = table.print();
    let mut terminal = term::stdout().unwrap();
    loop {
        thread::sleep(Duration::from_secs(1));
        table = TableManager {
            ascii_table: Table::new(),
            table_data: Vec::new()
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

pub fn setup_table(table: &mut TableManager, parsed_args: &ParsedArgs) -> Result<(), MultErrorTuple> {
    let tasks: Vec<Task> = TaskManager::get_tasks()?;
    for task in tasks.iter() {
        let command = match CommandManager::read_command_data(task.id) {
            Ok(result) => result,
            Err(err) => return Err(err)
        };
        let sys = System::new_all();

        let mut main_headers = MainHeaders {
            id: task.id,
            command: command.command.clone(),
        };
        let proc_stats = get_process_stats(command.pid as usize);
        println!("{:?} {} {} {} {}", proc_stats, proc_stats[21].parse::<u32>().unwrap(), command.starttime, command.pid, get_process_runtime(proc_stats[21].parse().unwrap()));
        if proc_stats.len() == 0 || command.starttime != proc_stats[21].parse().unwrap() {
            table.insert_row(main_headers, None);
            continue;
        }
        let mut cpu_usage = 0.0;
        let usage_stats = read_usage_stats(task.id)?;
        if let Some(stats) = usage_stats.get(&(command.pid as usize)) {
            cpu_usage = (stats.cpu_usage * 100.0).round() / 100.0;
        }
        // Get memory stats
        let mut process_headers = ProcessHeaders {
            pid: command.pid.to_string(),
            memory: get_process_memory(&(command.pid as usize)),
            cpu: cpu_usage.to_string(),
            runtime: get_process_runtime(proc_stats[21].parse().unwrap()).to_string(),
            status: color_string(OK_GREEN, "Running").to_string()
        };
        let process_tree = get_all_processes(command.pid as usize);

        let mut all_processes = vec![];
        compress_tree(&process_tree, &mut all_processes);
        if all_processes.len() > 1 {
            if parsed_args.flags.contains(&LIST_CHILDREN_FLAG.to_string()) {
                for child_process_id in all_processes.iter() {
                    if *child_process_id as u32 == command.pid { continue; }
                    if let Some(child_process) = sys.process(Pid::from_u32(*child_process_id as u32)) {
                        if let Some(stats) = usage_stats.get(child_process_id) {
                            cpu_usage = (stats.cpu_usage * 100.0).round() / 100.0;
                        }
                        main_headers.command.push_str(
                            &format!("\n {}", child_process.name())
                        );
                        process_headers.pid.push_str(
                            &format!("\n{}", child_process_id.to_string())
                        );
                        process_headers.memory.push_str(
                            &format!("\n{}", get_process_memory(child_process_id))
                        );
                        process_headers.cpu.push_str(
                            &format!("\n{}%", cpu_usage.to_string())
                        );
                        process_headers.runtime.push_str(
                            &format!("\n{}", child_process.run_time().to_string())
                        );
                        process_headers.status.push_str(
                            &format!("\n{}", color_string(OK_GREEN, "Running"))
                        );
                    }
                }
            } else {
                main_headers.command.push_str(
                    &format!("\n + {} more processes", all_processes.len() - 1)
                );
            }
        }

        table.insert_row(main_headers, Some(process_headers));
    }
    Ok(())
}

