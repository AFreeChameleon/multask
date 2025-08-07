# Mult

A daemoniser for linux, mac & windows written in rust. Inspired by [pm2](https://github.com/Unitech/pm2).

## Installation

For Linux:
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multi-tasker/master/install.sh" | bash
```

For Windows:
```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multi-tasker/master/install.ps1|iex"
```

## Getting Started

```
> mlt help
usage: mlt [options] [value]
options:
    create  Create a process and run it. [value] must be a command e.g "ping google.com"
    stop    Stops a process. [value] must be a task id e.g 0
    start   Starts a process. [value] must be a task id e.g 0
    restart Restarts a process. [value] must be a task id e.g 0
    ls      Shows all processes.
            --watch         Provides updating tables every 2 seconds.

    logs    Shows output from process. [value] must be a task id e.g 0
            --lines [num]   See number of previous lines, default is 15.
            --watch         Listen to new logs coming in.

    delete  Deletes process. [value] must be a task id e.g 0
    help    Shows available options.
    health  Checks state of mult, run this when mult is not working.
            --fix           Tries to fix any errors `mlt health` throws.
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

If mult isn't working, you can run:

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

