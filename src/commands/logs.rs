use home;
use notify::{RecursiveMode, Watcher};
use std::{
    collections::VecDeque,
    env,
    fs::{self, File},
    io::{BufRead, BufReader, Seek, SeekFrom},
    path::Path,
    sync::mpsc,
};

use mult_lib::{
    args::{parse_args, ParsedArgs},
    error::{print_error, print_info, MultError, MultErrorTuple},
    task::TaskManager,
};

const LINES_FLAG: &str = "-l";
const WATCH_FLAG: &str = "-w";
const FLAGS: [(&str, bool); 2] = [(LINES_FLAG, true), (WATCH_FLAG, false)];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, true)?;
    // Reading last 15 lines from stdout and stderr
    let last_lines_to_print: usize = get_last_lines_to_print(&parsed_args)?;

    let tasks = TaskManager::get_tasks()?;
    let task_id: u32 = TaskManager::parse_arg(env::args().nth(2))?;
    let _ = TaskManager::get_task(&tasks, task_id)?;

    let file_path = Path::new(&home::home_dir().unwrap())
        .join(".multi-tasker")
        .join("processes")
        .join(task_id.to_string());

    let out_file_path = file_path.join("stdout.out");
    let err_file_path = file_path.join("stderr.err");

    let mut out_file = File::open(&out_file_path).unwrap();
    let mut out_pos = fs::metadata(&out_file_path).unwrap().len();

    let mut err_file = File::open(&err_file_path).unwrap();
    let mut err_pos = fs::metadata(&err_file_path).unwrap().len();

    let mut combined_lines = read_last_lines(&out_file, last_lines_to_print)?;
    combined_lines.append(&mut read_last_lines(&err_file, last_lines_to_print)?);
    // Sorting lines by time
    let sorted_lines = sort_last_lines(combined_lines)?;
    print_info(&format!("Printing the last {} lines of logs.", last_lines_to_print).to_string());
    let start_idx = if sorted_lines.len() < last_lines_to_print {
        0
    } else {
        sorted_lines.len() - last_lines_to_print
    };
    for i in start_idx..sorted_lines.len() {
        print!("{}", sorted_lines[i].content);
    }
    if !parsed_args.flags.contains(&WATCH_FLAG.to_string()) {
        return Ok(());
    }

    let (tx, rx) = mpsc::channel();
    let mut out_watcher = notify::recommended_watcher(move |res| match res {
        Ok(_event) => {
            if out_file.metadata().unwrap().len() != out_pos {
                out_file.seek(SeekFrom::Start(out_pos + 1)).unwrap();
                out_pos = out_file.metadata().unwrap().len();
                let reader = BufReader::new(&out_file);
                for line in reader.lines() {
                    tx.send(line).unwrap();
                }
            }

            if err_file.metadata().unwrap().len() != err_pos {
                err_file.seek(SeekFrom::Start(err_pos + 1)).unwrap();
                err_pos = err_file.metadata().unwrap().len();
                let reader = BufReader::new(&err_file);
                for line in reader.lines() {
                    tx.send(line).unwrap();
                }
            }
        }
        Err(error) => print_error(
            MultError::CustomError,
            Some(format!("File watch error {error:?}")),
        ),
    })
    .unwrap();

    out_watcher
        .watch(Path::new(&file_path), RecursiveMode::Recursive)
        .unwrap();

    for res in rx {
        match res {
            Ok(line) => {
                let (_, content) = line.split_once("|").expect("Logs missing time.");
                println!("{content}")
            }
            Err(error) => print_error(
                MultError::CustomError,
                Some(format!("Reciever error {error:?}")),
            ),
        }
    }

    print_info("Logs stopped.");
    Ok(())
}

fn get_last_lines_to_print(parsed_args: &ParsedArgs) -> Result<usize, MultErrorTuple> {
    // Reading last 15 lines from stdout and stderr
    let mut last_lines_to_print: usize = 15;
    if let Some(line_count) = parsed_args
        .value_flags
        .clone()
        .into_iter()
        .find(|(flag, _)| flag == LINES_FLAG)
    {
        if line_count.1.is_some()
            && String::from(line_count.1.clone().unwrap())
                .parse::<usize>()
                .is_ok()
        {
            last_lines_to_print = match String::from(line_count.1.clone().unwrap()).parse::<usize>()
            {
                Ok(val) => val,
                Err(_) => return Err((MultError::InvalidArgument, Some(line_count.1.unwrap()))),
            };
        }
    }
    Ok(last_lines_to_print)
}

fn read_last_lines(file: &File, count: usize) -> Result<VecDeque<String>, MultErrorTuple> {
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut lines_cache = VecDeque::new();
    loop {
        let bytes_read = match reader.read_line(&mut line) {
            Ok(val) => val,
            Err(_) => return Err((MultError::CannotReadOutputFile, None)),
        };
        if bytes_read == 0 {
            break;
        }
        if lines_cache.len() == count {
            lines_cache.pop_front();
        }
        lines_cache.push_back(line.clone());
        line.clear();
    }
    Ok(lines_cache)
}

#[derive(Debug)]
struct Log {
    time_millis: u128,
    content: String,
}
fn sort_last_lines(lines: VecDeque<String>) -> Result<Vec<Log>, MultErrorTuple> {
    let mut new_lines = Vec::new();
    for line in lines.iter() {
        if let Some((time_string, content)) = line.split_once("|") {
            new_lines.push(Log {
                time_millis: time_string
                    .parse::<u128>()
                    .expect("Log time not a valid integer."),
                content: content.to_string(),
            });
        }
    }
    let mut sorted_lines: Vec<Log> = Vec::from(new_lines);
    sorted_lines.sort_by_key(|log: &Log| log.time_millis);
    Ok(sorted_lines)
}
