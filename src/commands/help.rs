use mult_lib::error::MultErrorTuple;

const HELP_TEXT: &str = "usage: mlt [options] [value]
options:
    create  Create a process and run it. [value] must be a command e.g \"ping google.com\"

    stop    Stops a process. [value] must be a task id e.g 0

    start   Starts a process. [value] must be a task id e.g 0

    restart Restarts a process. [value] must be a task id e.g 0

    ls      Shows all processes.

            --watch         Provides updating tables every 2 seconds.

    logs    Shows output from process. [value] must be a task id e.g 0
            
            --lines [num]   See number of previous lines default is 15.
            --watch         Listen to new logs coming in.

    delete  Deletes process. [value] must be a task id e.g 0

    help    Shows available options.

    health  Checks state of mult, run this when mult is not working.

            --fix           Tries to fix any errors `mlt health` throws.
";

pub fn run() -> Result<(), MultErrorTuple> {
    println!("{HELP_TEXT}");
    Ok(())
}
