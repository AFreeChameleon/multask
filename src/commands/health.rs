use std::fs::{self, File};
use std::os::linux::fs::MetadataExt;
use std::path::Path;
use std::env;

use home::home_dir;
use mult_lib::args::parse_args;
use mult_lib::error::{print_error, print_info, print_success, print_warning, MultError, MultErrorTuple};
use mult_lib::task::TaskManager;

extern "C" {
    pub fn init_cgroup(uid: libc::uid_t, gid: libc::gid_t) -> i32;
}

const FIX_FLAG: &str = "--fix";
const FLAGS: [(&str, bool); 1] = [
    (FIX_FLAG, false)
];

pub fn run() -> Result<(), MultErrorTuple> {
    let args = env::args();
    let parsed_args = parse_args(&args.collect::<Vec<String>>()[2..], &FLAGS, false)?;
    let mut fix_enabled = false;
    if parsed_args.flags.contains(&FIX_FLAG.to_string()) {
        print_info("Fix flag enabled.");
        fix_enabled = true;
    }
    print_info("Running health check...");
    match run_tests(fix_enabled) {
        Ok(()) => print_success("No failures detected."),
        Err(Some((err, descriptor))) => print_error(err, descriptor),
        Err(_) => ()
    };
    Ok(())
}

fn run_tests(fix_enabled: bool) -> Result<(), Option<MultErrorTuple>> {
    // Initial checks
    let tasks_dir = Path::new(&home_dir().unwrap())
        .join(".multi-tasker");
    if !tasks_dir.exists() && !tasks_dir.is_dir() {
        if !fix_enabled {
            return Err(Some((MultError::MainDirNotExist, None)))
        }
        create_main_dir()?;
    } else {
        print_success("Main directory exists.");
    }
    // Check tasks file exists
    let processes_dir = tasks_dir.join("processes");
    let mut processes = match check_processes_dir(&processes_dir) {
        Ok(val) => {
            print_success("Processes directory exists.");
            val
        },
        Err(msg) => {
            if !fix_enabled {
                return Err(Some(msg));
            }
            create_process_dir()?;
            Vec::new()
        }
    };
    // Checking for processes while no task file exists
    if !tasks_dir.join("tasks.bin").exists() {
        for name in &processes {
            print_error(MultError::UnknownProcessInDir, Some(name.to_string()));
        }
        if !fix_enabled {
            return Err(None)
        }
    } else {
        print_success("Tasks file exists.");
    }
    
    let tasks = match TaskManager::get_tasks() {
        Ok(val) => {
            print_success("Tasks file read.");
            val
        },
        Err(msg) => {
            if !fix_enabled {
                return Err(Some(msg));
            }
            Vec::new()
        }
    };
    // Check process dir, log files & data binary
    for task in tasks.iter() {
        if processes.contains(&task.id.to_string()) {
            processes = processes
                .into_iter()
                .filter(|process: &String| process != &task.id.to_string())
                .collect();
        }
        match TaskManager::test_task_files(task.id) {
            Ok(()) => (),
            Err((err, desc)) => { print_error(err, desc); } 
        };
    }
    print_success("Task logs read.");
    for process in &processes {
        print_error(MultError::UnknownProcessInDir, Some(process.to_string()));
        if !fix_enabled {
            delete_process(process.to_string())?;
        }
    }
    check_cgroups();
    Ok(())
}

fn check_cgroups() {
    // Gets owner of who installed mult
    let exe_loc = env::current_exe().unwrap().display().to_string();
    if !Path::new("/sys/fs/cgroup/mult").exists() {
        print_info("Generating cgroups...");
        let exe_meta = fs::metadata(Path::new(&exe_loc)).unwrap();
        let err = unsafe { init_cgroup(exe_meta.st_uid(), exe_meta.st_gid()) };
        if err == libc::EACCES {
            print_warning("Root needed to create cgroups for resource limits on tasks. Run: `sudo mlt health --fix`.");
        }
    }
}

fn check_processes_dir(processes_dir: &Path) -> Result<Vec<String>, MultErrorTuple> {
    let mut name_entries = Vec::new();
    if processes_dir.exists() && processes_dir.is_dir() {
        let entries = match fs::read_dir(processes_dir) {
            Ok(val) => val,
            Err(_) => return Err((MultError::FailedReadingProcessDir, None))
        };
        for entry in entries {
            let entry = match entry {
                Ok(val) => val,
                Err(_) => return Err((MultError::FailedFormattingProcessEntry, None))
            };
            let Ok(file_name) = entry.file_name().into_string() else {
                print_error(MultError::FailedConvertingProcessEntry, None);
                continue;
            };
            name_entries.push(file_name);
        }
    } else {
        return Err((MultError::ProcessDirNotExist, None))
    }
    Ok(name_entries)
}

fn create_main_dir() -> Result<(), MultErrorTuple> {
    let home_dir_string = home_dir().unwrap();
    let home = Path::new(&home_dir_string);
    let main_dir = home.join(".multi-tasker/");
    fs::create_dir(main_dir).unwrap();
    print_success("Created main dir.");
    Ok(())
}

fn create_process_dir() -> Result<(), MultErrorTuple> {
    let home_dir_string = home_dir().unwrap();
    let home = Path::new(&home_dir_string);
    let processes_dir = home.join(".multi-tasker/processes/");
    fs::create_dir(processes_dir).unwrap();
    print_success("Created processes dir.");
    Ok(())
}

fn delete_process(process: String) -> Result<(), MultErrorTuple> {
    let home_dir_string = home_dir().unwrap();
    let home = Path::new(&home_dir_string);
    let process_dir = home.join(format!(".multi-tasker/processes/{}", process));
    if process_dir.is_dir() {
        fs::remove_dir_all(&process_dir).unwrap();
    } else if process_dir.is_file() {
        fs::remove_file(&process_dir).unwrap();
    }
    print_success(format!(
        "Deleted unknown process: {}",
        &process_dir.display().to_string()).as_str()
    );
    Ok(())
}
