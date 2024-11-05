use mult_lib::error::MultErrorTuple;

const HELP_TEXT: &str = "usage: mlt [options] [value]
options:
    create  Create a process and run it. [value] must be a command e.g \"ping google.com\"

            -m [num]    Set maximum memory limit e.g 4GB
            -c [num]    Set limit cpu usage by percentage e.g 20
            -i          Interactive mode (can use aliased commands on your environment)

    stop    Stops a process. [value] must be a task id e.g 0

    start   Starts a process. [value] must be a task id e.g 0

            -m [num]    Set maximum memory limit e.g 4GB
            -c [num]    Set maximum cpu percentage limit e.g 20
            -i          Interactive mode (can use aliased commands on your environment)

    restart Restarts a process. [value] must be a task id e.g 0

            -m [num]    Set maximum memory limit e.g 4GB
            -c [num]    Set maximum cpu percentage limit e.g 20
            -i          Interactive mode (can use aliased commands on your environment)

    ls      Shows all processes.

            -w          Provides updating tables every 2 seconds.
            -a          Show all child processes.

    logs    Shows output from process. [value] must be a task id e.g 0
            
            -l [num]   See number of previous lines default is 15.
            -w         Listen to new logs coming in.

    delete  Deletes process. [value] must be a task id e.g 0

    health  Checks state of multask, run this when multask is not working.

            -f          Tries to fix any errors `mlt health` throws.

    help    Shows available options.
";

pub fn run() -> Result<(), MultErrorTuple> {
    println!("{HELP_TEXT}");
    Ok(())
}
