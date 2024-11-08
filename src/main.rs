use commands::{create, delete, health, help, logs, ls, restart, start, stop};
use mult_lib::error::{print_error, MultError};
use std::env::args;

mod commands;

const NO_MODE_TEXT: &str = "No mode given.\n
For a full list of commands: mlt help";
fn main() {
    #[cfg(target_family = "windows")]
    {
        use mult_lib::colors::set_virtual_terminal;
        set_virtual_terminal(true).unwrap();
    }
    if let Some(mode) = args().nth(1) {
        if let Err((message, descriptor)) = match mode.as_str() {
            "create" => create::run(),
            "start" => start::run(),
            "stop" => stop::run(),
            "restart" => restart::run(),
            "logs" => logs::run(),
            "delete" => delete::run(),
            "help" => help::run(),
            "ls" => ls::run(),
            "health" => health::run(),
            _ => Err((MultError::MissingCommand, None)),
        } {
            print_error(message, descriptor);
        }
    } else {
        print_error(MultError::CustomError, Some(NO_MODE_TEXT.to_string()));
    }
}
