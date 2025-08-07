use std::{thread, time::Duration, env};
use mult_lib::args::parse_args;
use prettytable::Table;
use sysinfo::{System, Pid};

use mult_lib::error::{MultError, MultErrorTuple};
use mult_lib::table::{MainHeaders, ProcessHeaders, TableManager};
use mult_lib::task::{Task, TaskManager};
use mult_lib::command::CommandManager;

const WATCH_FLAG: &str = "--watch";
const FLAGS: [(&str, bool); 1] = [
    (WATCH_FLAG, false)
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, false)?;
    let mut table = TableManager {
        ascii_table: Table::new(),
        table_data: Vec::new()
    };
    table.create_headers();
    setup_table(&mut table)?;
    if parsed_args.flags.contains(&WATCH_FLAG.to_string()) {
        if cfg!(target_family = "windows") {
            return Err((MultError::WindowsNotSupported, Some("--watch".to_string())));
        }
        listen()?;
    } else {
        table.print();
    }

    Ok(())
}

fn listen() -> Result<(), MultErrorTuple> {
    let mut table = TableManager {
        ascii_table: Table::new(),
        table_data: Vec::new()
    };
    table.create_headers();
    setup_table(&mut table)?;
    let mut height = table.print();
    let mut terminal = term::stdout().unwrap();
    loop {
        thread::sleep(Duration::from_secs(2));
        table = TableManager {
            ascii_table: Table::new(),
            table_data: Vec::new()
        };
        table.create_headers();
        setup_table(&mut table)?;
        for _ in 0..height {
            terminal.cursor_up().unwrap();
            terminal.delete_line().unwrap();
        }
        height = table.print();
    }
}

pub fn setup_table(table: &mut TableManager) -> Result<(), MultErrorTuple> {
    let tasks: Vec<Task> = TaskManager::get_tasks()?;
    for task in tasks.iter() {
        let command = match CommandManager::read_command_data(task.id) {
            Ok(result) => result,
            Err(err) => return Err(err)
        };
        let sys = System::new_all();

        let main_headers = MainHeaders {
            id: task.id,
            command: command.command,
        };
        if let Some(process) = sys.process(Pid::from_u32(command.pid)) {
            if process.name() != command.name {
                table.insert_row(main_headers, None);
                continue;
            }
            // Get memory stats
            let process_headers = ProcessHeaders {
                pid: command.pid,
                memory: process.memory(),
                cpu: process.cpu_usage(),
                runtime: process.run_time(),
                status: "Running".to_string()
            };

            table.insert_row(main_headers, Some(process_headers));
        } else {
            table.insert_row(main_headers, None);
        }
    }
    Ok(())
}

