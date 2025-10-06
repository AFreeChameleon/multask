# Getting Started

Multask is a program that organises running multiple commands complete with flexible resource monitoring and limiting.

Available on Windows, Macos and Linux.

To get more detail on a command, run:
```
> mlt [command e.g create] -h
```

## Commands

Create a new task by typing:

```
> mlt create "ping google.com"
```

This will start a new process running the command specified.

To see your running tasks, run:
```
> mlt ls

+----+-----------+--------------+-------------------------+-----+---------+--------+-----+---------+------------+
| id | namespace | command      | location                | pid | status  | memory | cpu | runtime | monitoring |
+----+-----------+--------------+-------------------------+-----+---------+--------+-----+---------+------------+
| 1  | N/A       | ping 8.8.8.8 | F:\Dev\Apps\multask-zig | N/A | Stopped | N/A    | N/A | N/A     | shallow    |
+----+-----------+--------------+-------------------------+-----+---------+--------+-----+---------+------------+
```

* `id` is how you'll be referencing this task in other commands.
* `namespace` is a name to organise and address multiple tasks. 
* `command` what command is run.
* `location` what directory/folder the command was run from.
* `pid` the process id in the OS.
* `status` the status of the command, options are `Running`, `Stopped`, `Detached` or `Headless`, run `mlt ls -h` for more info.
* `memory` amount of memory being used by this task.
* `cpu` percentage of cpu being used by this task.
* `runtime` how long this command has been running for (in seconds).
* `monitoring` how thorough the task is looking for potential child processes, `shallow` is the default, `deep` is for thorough searching.

To stop the new task, run:

```
> mlt stop 1
```

To start the task again, run:

```
> mlt start 1
```

To restart the task, run:

```
> mlt restart 1
```

To delete the task and all logs, run:

```
> mlt delete 1
```

If multask isn't working, you can run:

```
> mlt health
```

To see what's wrong with it. This is mainly for debugging purposes.

For a more general list of all commands and their options, run `mlt help`.
```
> mlt help
Usage: mlt [option] [flags] [values]
To see an individial command's options, run `mlt [command] -h`
options:

mlt create
Creates and starts a task by entering a command.
Usage: mlt create -m 20M -c 50 -n ns_one -i -p "ping google.com"
Flags:
        -m [num]                Set maximum memory limit e.g 4GB
        -c [num]                Set limit cpu usage by percentage e.g 20
        -n [text]               Set namespace for the process
        -i                      Interactive mode (can use aliased commands on your environment)
        -p                      Persist mode (will restart if the program exits)
        -b, --boot              Run this task on startup.
        -s, --search [text]     Makes this task look for child processes more thoroughly. Can either set to `deep` or `shallow`.
        --no-run                Don't run the task after creation.


mlt stop
Stops tasks by task id or namespace
Usage: mlt stop all


mlt start
Starts tasks by task id or namespace
Usage: mlt start -m 100M -c 50 -i -p all
Flags:
        -m [num]                Set maximum memory limit e.g 4GB. Set to `none` to remove it.
        -c [num]                Set limit cpu usage by percentage e.g 20. Set to `none` to remove it.
        -i                      Interactive mode (can use aliased commands on your environment)
        -I                      Disable interactive mode
        -p                      Persist mode (will restart if the program exits)
        -P                      Disable persist mode
        -e                      Updates env variables with your current environment.
        -s, --search [text]     Makes this task look for child processes more thoroughly. Can either set to `deep` or `shallow`.


mlt edit
Can change resource limits of tasks by task id or namespace
Usage: mlt edit -m 40M -c 20 -n ns_two 1 2
Flags:
        -m [num]                Set maximum memory limit e.g 4GB. Set to `none` to remove it.
        -c [num]                Set limit cpu usage by percentage e.g 20. Set to `none` to remove it.
        -i                      Interactive mode (can use aliased commands on your environment)
        -I                      Disable interactive mode
        -p                      Persist mode (will restart if the program exits)
        -P                      Disable persist mode
        -b, --boot              Run this task on startup.
        -B, --disable-boot      Stop running this task on startup.
        -e                      Updates env variables with your current environment. You'll have to restart the process for this to take effect    
        -s, --search [text]     Makes this task look for child processes more thoroughly. Can either set to `deep` or `shallow`.
        --comm [text]           Set the command to run.


mlt restart
Restarts tasks by task id or namespace
Usage: mlt restart -m 100M -c 50 -i -p all
Flags:
        -m [num]                Set maximum memory limit e.g 4GB. Set to `none` to remove it.
        -c [num]                Set limit cpu usage by percentage e.g 20. Set to `none` to remove it.
        -i                      Interactive mode (can use aliased commands on your environment)
        -I                      Disable interactive mode
        -p                      Persist mode (will restart if the program exits)
        -P                      Disable persist mode
        -e                      Updates env variables with your current environment.
        -s, --search [text]     Makes this task look for child processes more thoroughly. Can either set to `deep` or `shallow`.


mlt ls
Gets stats and resource usage of tasks
Usage: mlt ls -w -a [task ids or namespaces OPTIONAL]
Flags:
        -w, -f                  Updates tables every 2 seconds.
        -a                      Show all child processes under each task.
        -s                      Show stats for each task e.g resource limits and flags.

A task's different states are:
Running         The process is running
Stopped         The task is stopped
Detached        The main process in the task has stopped, but it has child processes that are still running.
Headless        The main process is running, but the multask daemon is not. This is bad and the task should be restarted.


mlt logs
Reads logs of the task
Usage: mlt logs -l 1000 -w 1
Flags:
        -l [num]                Get number of previous lines, default is 20
        -w, -f                  Listen to new logs coming in


mlt delete
Deletes tasks and kills any process that's running under them.
Usage: mlt delete 1 2 ns_one


mlt health
Checks each task to see if they are healthy and not corrupted.
Run this when this tool breaks.
Usage: mlt health
```
