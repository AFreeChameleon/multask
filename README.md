<div align="center">
  <a href="https://afreechameleon.github.io/multask-docs/">
    <img src="https://github.com/afreechameleon/multask-docs/blob/master/images/gecko.png?raw=true" alt="Logo" width="150" height="150">
  </a>

  <h1 align="center">Multask</h1>

  <p align="center">
    A process manager for Linux, Mac, Windows & FreeBSD to simplify your developer environment.
  </p>
  <p align="center">
    <a href="https://afreechameleon.github.io/multask-docs/">Docs</a>
  </p>
  <p align="center">
    Designed to organise projects which need processes running at the same time with flexible resource limits for scaling.
  </p>
  <p align="center">
    <a href="https://www.youtube.com/watch?v=KVUPj4636hE">Watch the demo</a>
  </p>
  <a href="https://www.youtube.com/watch?v=KVUPj4636hE">
    <img src="https://img.youtube.com/vi/KVUPj4636hE/0.jpg" alt="Demo video">
  </a>
</div>

## Installation

**For Linux:**
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/linux.sh" | bash
```

**For Mac:**
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/osx.sh" | bash
```

**For FreeBSD:**

Multask's newest version is currently not supporting FreeBSD. So in the meantime the older version can still be used. [here](https://github.com/AFreeChameleon/multask/releases/tag/0.20.0)

Bash & ZSH officially supported.

**For Windows:**
```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/win.ps1|iex"
```

## Getting Started

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

To get more detail on a command, run:
```
> mlt <command e.g create> -h
```


Create a daemon process by typing:

```
> mlt create "ping google.com"
```

This will start a new daemon process running the command specified.

To see your running processes, run:
```
> mlt ls

+----+-----------+--------------+-------------------------+-----+---------+--------+-----+---------+------------+
| id | namespace | command      | location                | pid | status  | memory | cpu | runtime | monitoring |
+----+-----------+--------------+-------------------------+-----+---------+--------+-----+---------+------------+
| 1  | N/A       | ping 8.8.8.8 | F:\Dev\Apps\multask-zig | N/A | Stopped | N/A    | N/A | N/A     | shallow    |
+----+-----------+--------------+-------------------------+-----+---------+--------+-----+---------+------------+
```

* `id` is how you'll be referencing this process in other commands.
* `namespace` is a name to organise and address multiple tasks. 
* `command` what command is run.
* `location` what directory/folder the command was run from.
* `pid` the process id in the OS.
* `status` the status of the command, options are `Running`, `Stopped`, `Detached` or `Headless`, run `mlt ls -h` for more info.
* `memory` amount of memory being used by this process.
* `cpu` percentage of cpu being used by this process.
* `runtime` how long this command has been running for (in seconds).
* `monitoring` how thorough the task is looking for potential child processes, `shallow` is the default, `deep` is for thorough searching.

To stop the new process, run:

```
> mlt stop 1
```

To start the process again, run:

```
> mlt start 1
```

To restart the process, run:

```
> mlt restart 1
```

To delete the process and all logs, run:

```
> mlt delete 1
```

If multask isn't working, you can run:

```
> mlt health
```

To see what's wrong with it. This is mainly for debugging purposes.

---

Licensed under either of

* Apache License, Version 2.0 (LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0)
* MIT license (LICENSE-MIT or http://opensource.org/licenses/MIT) at your option.
