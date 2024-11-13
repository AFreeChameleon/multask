use std::{fs, io::stdin, path::Path};

use mult_lib::error::{print_error, print_success, print_warning, MultError, MultErrorTuple};

pub fn run() -> Result<(), MultErrorTuple> {
    let main_dir = Path::new(&home::home_dir().unwrap())
        .join(".multi-tasker");
    print_warning("Are you sure you want to uninstall? [y/n]");
    let mut response = String::new();
    stdin().read_line(&mut response).unwrap();
    if response.to_lowercase().trim() == "y" {
        match fs::remove_dir_all(main_dir) {
            Ok(val) => val,
            Err(_) => return Err((MultError::MainDirNotExist, None))
        };
        print_success("Multask has been uninstalled. Thanks for using it!");
    } else {
        print_error(MultError::CustomError, Some("Uninstall aborted.".to_string()));
    }
    Ok(())
}
