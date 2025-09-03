# Getting Started

Multask is a program that organises running multiple commands complete with flexible resource monitoring and limiting.

Available on Windows, Macos and Linux.

## Commands

To get more detail on a command, run:
```
> mlt [command e.g create] -h
```

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
options:
        create  Create a task and run it. [value] must be a command e.g "ping google.com"
                -m [num]        Set maximum memory limit e.g 4GB
                -c [num]        Set limit cpu usage by percentage e.g 20
                -n [text]       Set namespace for the task
                -i              Interactive mode (can use aliased commands on your environment)
                -p              Persist mode (will restart if the program exits)
                -M, --monitor   How thorough looking for child processes will be, use "deep" for complex applications like GUIs although it can be a little more CPU intensive, "shallow" is the default.

        stop    Stops a task. [value] must be task ids or a namespace

        start   Starts a task. [value] must be task ids or a namespace
                -m [num]        Set maximum memory limit e.g 4GB
                -c [num]        Set limit cpu usage by percentage e.g 20
                -i              Interactive mode (can use aliased commands on your environment)
                -p              Persist mode (will restart if the program exits)
                -e              Updates env variables with your current environment.
                -M, --monitor   How thorough looking for child processes will be, use "deep" for complex applications like GUIs although it can be a little more CPU intensive, "shallow" is the default.

        edit    Edits a task. [value] must be task ids or a namespace
                -m [num]        Set maximum memory limit e.g 4GB
                -c [num]        Set limit cpu usage by percentage e.g 20
                -n [text]       Set namespace for the task
                -p              Persist mode (will restart if the program exits)
                -M, --monitor   How thorough looking for child processes will be, use "deep" for complex applications like GUIs although it can be a little more CPU intensive, "shallow" is the default.

        restart Restarts a task. [value] must be task ids or a namespace
                -m [num]        Set maximum memory limit e.g 4GB
                -c [num]        Set limit cpu usage by percentage e.g 20
                -i              Interactive mode (can use aliased commands on your environment)
                -p              Persist mode (will restart if the program exits)
                -e              Updates env variables with your current environment.
                -M, --monitor   How thorough looking for child processes will be, use "deep" for complex applications like GUIs although it can be a little more CPU intensive, "shallow" is the default.

        ls      Shows all taskes
                -w      Provides updating tables every 2 seconds
                -a      Show all child taskes

        logs    Shows output from task. [value] must be a task id e.g 1
                -l [num]        See number of previous lines default is 20
                -w              Listen to new logs coming in

        delete  Deletes tasks. [value] must be a task id or a namespace e.g 1

        health  Checks state of multask, run this when multask is not working

        help    Shows available options
```
