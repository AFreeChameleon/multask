
use std::{
    process::{Command, Stdio, ChildStdout, ChildStderr},
    io::Write,
    sync::{Mutex, mpsc, Arc},
    fs::{self, File, OpenOptions},
    thread,
    time::Duration,
    env::args,
    path::Path
};
use home;
use serde::Serialize;
use bincode;
use glob;

use crate::task::{Task, TaskManager};
use crate::command::{CommandData, CommandManager};
use crate::linux;

pub fn run() -> Result<(), String> {
    let mut tasks: Vec<Task> = TaskManager::get_tasks();
    let task_id: u32 = match args().nth(2) {
        Some(arg) => match arg.parse::<u32>() {
            Ok(id) => id,
            Err(_) => return Err("Invalid id, usage: mult start \"[command]\"".to_string())
        },
        None => return Err("Missing/invalid id, usage: mult start \"[command]\"".to_string())
    };
    let task: Task = match tasks.iter().find(|&t| t.id == task_id).cloned() {
        Some(t) => t,
        None => return Err("No task exists with that id, use mult ls to see the available tasks.".to_string())
    };
    let command_data = match CommandManager::read_command_data(task.id) {
        Ok(data) => data,
        Err(message) => return Err(message)
    };
    let files = TaskManager::generate_task_files(task.id, tasks);
    println!("Running command...");
    if cfg!(target_os = "linux") {
        linux::daemonize_task(files, command_data.command);
    } else {
        println!("Linux is only supported at the moment");
    }
    Ok(())
}
