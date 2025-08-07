<div align="center">
  <a href="https://afreechameleon.github.io/multask-docs/">
    <img src="https://github.com/afreechameleon/multask-docs/blob/develop/images/gecko.png?raw=true" alt="Logo" width="150" height="150">
  </a>

  <h1 align="center">Multask</h1>

  <p align="center">
    A process manager for Linux, Mac, Windows & FreeBSD written in rust to simplify your developer environment.
  </p>
  <p align="center">
    <a href="https://afreechameleon.github.io/multask-docs/">Docs</a>
  </p>
  <p align="center">
    Designed to organise projects which need processes running at the same time with flexible resource limits for scaling.
  </p>
</div>

## Installation

For Linux, Mac & FreeBSD:
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/linux.sh" | bash
```

For Mac:
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/osx.sh" | bash
```

For FreeBSD:
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/freebsd.sh" | bash
```

For Windows:
```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multask-docs/refs/heads/master/install/scripts/win.ps1|iex"
```

## Getting Started

```
> mlt help
usage: mlt [options] [value]
options:
    create  Create a process and run it. [value] must be a command e.g \"ping google.com\"
        -m [num]    Set maximum memory limit e.g 4GB
        -c [num]    Set limit cpu usage by percentage e.g 20
        -i          Interactive mode (can use aliased commands on your environment)
        -p          Persist mode, the command will restart when finished with a wait of 2 seconds

    stop    Stops a process. [value] must be a task id e.g 0

    start   Starts a process. [value] must be a task id e.g 0
        -m [num]    Set maximum memory limit e.g 4GB
        -c [num]    Set maximum cpu percentage limit e.g 20
        -i          Interactive mode (can use aliased commands on your environment)
        -p          Persist mode, the command will restart when finished with a wait of 2 seconds

    restart Restarts a process. [value] must be a task id e.g 0
        -m [num]    Set maximum memory limit e.g 4GB
        -c [num]    Set maximum cpu percentage limit e.g 20
        -i          Interactive mode (can use aliased commands on your environment)
        -p          Persist mode, the command will restart when finished with a wait of 2 seconds

    ls      Shows all processes.
        -w          Provides updating tables every 2 seconds.
        -a          Show all child processes.

    logs    Shows output from process. [value] must be a task id e.g 0
        -l [num]   See number of previous lines default is 15.
        -w         Listen to new logs coming in.

    delete  Deletes process. [value] must be a task id e.g 0

    health  Checks state of mult, run this when multask is not working.
        -f          Tries to fix any errors `mlt health` throws.

    help    Shows available options.
```


Create a daemon process by typing:

```
> mlt create "ping google.com"
```

This will start a new daemon process running the command specified.

To see your running processes, run:
```
> mlt ls

┌────┬─────────────────┬───────┬─────────┬─────────┬─────┬─────────┐
│ id │ command         │ pid   │ status  │ memory  │ cpu │ runtime │
├────┼─────────────────┼───────┼─────────┼─────────┼─────┼─────────┤
│ 0  │ ping google.com │ 12502 │ Running │ 9.9 MiB │ 0   │ 16      │
└────┴─────────────────┴───────┴─────────┴─────────┴─────┴─────────┘
```

* `id` is how you'll be referencing this process in other commands.
* `command` what command is run.
* `pid` the process id in the OS.
* `status` the status of the command, options are either `Running` or `Stopped`.
* `memory` percentage of memory being used by this process.
* `cpu` percentage of cpu being used by this process.
* `runtime` how long this command has been running for (in seconds).

To stop the new process, run:

```
> mlt stop 0
```

To start the process again, run:

```
> mlt start 0
```

To restart the process, run:

```
> mlt restart 0
```

To delete the process and all logs, run:

```
> mlt delete 0
```

If multask isn't working, you can run:

```
> mlt health
```

To see what's wrong with it. This is mainly for debugging purposes.

---

# Issues

Any command run will not include colors so in the command or your environment, force the formatting e.g using FORCE_COLOR=1 in nodejs

---

Licensed under either of

* Apache License, Version 2.0 (LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0)
* MIT license (LICENSE-MIT or http://opensource.org/licenses/MIT) at your option.

## Things to do:
* Add watch support to other OSes
* Move from threads to async - will change a lot
