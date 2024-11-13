use std::{env, fs, io::stdin, path::Path, process::Command};

use mult_lib::error::{print_error, print_success, print_warning, MultError, MultErrorTuple};

pub fn run() -> Result<(), MultErrorTuple> {

    #[cfg(target_os = "linux")]
    Command::new(env::var("SHELL").unwrap())
        .args(["-c", "curl -s \"https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/install/scripts/linux.sh\" | bash"])
        .spawn()
        .expect("Command has failed.");
    #[cfg(target_os = "freebsd")]
    Command::new(env::var("SHELL").unwrap())
        .args(["-c", "curl -s \"https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/install/scripts/freebsd.sh\" | bash"])
        .spawn()
        .expect("Command has failed.");
    #[cfg(target_os = "macos")]
    Command::new(env::var("SHELL").unwrap())
        .args(["-c", "curl -s \"https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/install/scripts/osx.sh\" | bash"])
        .spawn()
        .expect("Command has failed.");
    #[cfg(target_os = "windows")]
    Command::new(env::var("SHELL").unwrap())
        .args(["-c", "powershell -c \"irm https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/docs/install/scripts/win.ps1|iex\""])
        .spawn()
        .expect("Command has failed.");

    Ok(())
}
