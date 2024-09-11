use mult_lib::args::{parse_args, ParsedArgs};
use mult_lib::colors::{color_string, OK_GREEN};
use mult_lib::linux::proc::linux_get_all_processes;
use mult_lib::proc::{get_proc_comm, proc_exists};
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
        let process_headers_opt =
            get_process_headers(command.pid as usize, command.starttime, &task, true);
        if process_headers_opt.is_none() {
            table.insert_row(main_headers, None);
            continue;
        }
        let mut process_headers = process_headers_opt.unwrap();
        let process_tree;
        #[cfg(target_os = "linux")] {
            process_tree = linux_get_all_processes(command.pid as usize);
        }
        #[cfg(target_os = "windows")] {
            use std::ffi::OsString;
            use mult_lib::windows::proc::win_get_all_processes;
            use windows_sys::Win32::System::JobObjects::OpenJobObjectW;
            process_tree = win_get_all_processes(
                unsafe {
                    OpenJobObjectW(
                        0x1F001F, // JOB_OBJECT_ALL_ACCESS
                        0,
                        OsString::from(format!("Global\\mult-{}", task.id))
                        .encode_wide().chain(Some(0)).collect::<Vec<u16>>().as_ptr() as *const u16,
                    )
                },
                command.pid,
            );
        }

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
                    if let Some(child_process_headers) =
                        get_process_headers(*child_process_id, command.starttime, &task, false)
                    {
                        main_headers
                            .command
                            .push_str(&format!("\n  {}", get_proc_comm(*child_process_id as u32)?));
                        process_headers
                            .pid
                            .push_str(&format!("\n{}", child_process_headers.pid));
                        process_headers
                            .memory
                            .push_str(&format!("\n{}", child_process_headers.memory));
                        process_headers
                            .cpu
                            .push_str(&format!("\n{}", &child_process_headers.cpu));
                        process_headers
                            .runtime
                            .push_str(&format!("\n{}", child_process_headers.runtime));
                        process_headers
                            .status
                            .push_str(&format!("\n{}", color_string(OK_GREEN, "Running")));
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

fn get_process_headers(
    pid: usize,
    starttime: u32,
    task: &Task,
    is_main_process: bool,
) -> Option<ProcessHeaders> {
    #[cfg(target_os = "linux")]
    return linux_get_process_headers(pid, starttime, task, is_main_process);
    #[cfg(target_os = "windows")]
    return win_get_process_headers(pid, starttime, task, is_main_process);
}

#[cfg(target_os = "windows")]
fn win_get_process_headers(
    pid: usize,
    _starttime: u32,
    task: &Task,
    is_main_process: bool,
) -> Option<ProcessHeaders> {
    use std::ffi::OsString;
    use mult_lib::{
        error::print_error,
        proc::{get_readable_runtime, read_usage_stats},
        windows::proc::{win_get_memory_usage, win_get_process_runtime, win_get_process_stats},
    };
    use windows_sys::Win32::{
        Foundation::GetLastError,
        System::{
            JobObjects::IsProcessInJob,
            Threading::{OpenProcess, PROCESS_QUERY_INFORMATION},
        },
    };

    let lp_name: Vec<u16> = OsString::from(format!("Global\\mult-{}", task.id))
        .encode_wide().chain(Some(0)).collect();

    // Check if job object exists already
    let job = unsafe {
        OpenJobObjectW(
            0x1F001F, // JOB_OBJECT_QUERY
            0,
            lp_name.as_ptr(),
        )
    };
    let process = unsafe { OpenProcess(PROCESS_QUERY_INFORMATION, 1, pid as u32) };
    if process.is_null() || (is_main_process && job.is_null()) {
        return None;
    }
    let mut is_process_in_job: i32 = 0;
    unsafe {
        if IsProcessInJob(process, job, &mut is_process_in_job) == 0 {
            print_error(MultError::WindowsError, Some(GetLastError().to_string()));
            return None;
        }
    }
    if is_process_in_job == 0 {
        return None;
    }

    let proc_stats = win_get_process_stats(pid);
    if proc_stats.len() == 0 {
        return None;
    }
    let mut cpu_usage = 0.0;
    let usage_stats = match read_usage_stats(task.id) {
        Ok(val) => val,
        Err(_) => return None,
    };
    if let Some(stats) = usage_stats.get(&(pid as usize)) {
        cpu_usage = (stats.cpu_usage * 100.0).round() / 100.0;
    }

    Some(ProcessHeaders {
        pid: pid.to_string(),
        memory: win_get_memory_usage(&(pid as usize)),
        cpu: format!("{}%", cpu_usage),
        runtime: get_readable_runtime(win_get_process_runtime(proc_stats[2].parse().unwrap())),
        status: color_string(OK_GREEN, "Running").to_string(),
    })
}

#[cfg(target_os = "linux")]
fn linux_get_process_headers(
    pid: usize,
    starttime: u32,
    task: &Task,
    is_main_process: bool,
) -> Option<ProcessHeaders> {
    use mult_lib::{linux::proc::{linux_get_process_memory, linux_get_process_runtime, linux_get_process_stats}, proc::{get_readable_runtime, read_usage_stats}};
    let proc_stats = linux_get_process_stats(pid as usize);
    if is_main_process && (proc_stats.len() == 0 || starttime != proc_stats[21].parse().unwrap()) {
        return None;
    }
    let mut cpu_usage = 0.0;
    let usage_stats = match read_usage_stats(task.id) {
        Ok(val) => val,
        Err(_) => return None,
    };
    if let Some(stats) = usage_stats.get(&(pid as usize)) {
        cpu_usage = (stats.cpu_usage * 100.0).round() / 100.0;
    }
    // Get memory stats
    Some(ProcessHeaders {
        pid: pid.to_string(),
        memory: linux_get_process_memory(&(pid as usize)),
        cpu: format!("{}%", cpu_usage),
        runtime: get_readable_runtime(linux_get_process_runtime(proc_stats[21].parse().unwrap()) as u64),
        status: color_string(OK_GREEN, "Running").to_string(),
    })
}
