# Resource monitoring and limiting

## Monitoring

In multask, you can monitor the memory and CPU usage of each task. To do this, run:
```
> mlt ls
```

Which will show a table of all of the tasks you've created with their status:
```
+----+-----------+--------------------+--------------------------+-------+---------+---------+------+----------+--------+
| id | namespace | command            | location             | pid   | status  | memory  | cpu  | runtime  | monitoring |
+----+-----------+--------------------+----------------------+-------+---------+---------+------+----------+------------+
| 1  | N/A       | sleep 5 && echo hi | ...dev/tools/multask | 88476 | Running | 3.4 MiB | 0.00 | 0h 0m 2s | shallow    |
|    |           |  + 1 more process  |                      |       |         |         |      |          |            |
+----+-----------+--------------------+--------------------------+-------+---------+---------+------+----------+--------+
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

And to see any child processes as well as their resource usage created by this task, you use the `-a` flag:

```
+----+-----------+--------------------+----------------------+-------+---------+---------+------+----------+------------+
| id | namespace | command            | location             | pid   | status  | memory  | cpu  | runtime  | monitoring |
+----+-----------+--------------------+----------------------+-------+---------+---------+------+----------+------------+
| 1  | N/A       | sleep 5 && echo hi | ...dev/tools/multask | 88881 | Running | 3.4 MiB | 0.00 | 0h 0m 2s | shallow    |
|    |           | sleep              | ...dev/tools/multask | 88882 | Running | 908 KiB | 0.00 | 0h 0m 2s |            |
+----+-----------+--------------------+----------------------+-------+---------+---------+------+----------+------------+
```

To have a realtime view of the table, add the `-w` flag to get a table that updates every second with new data.

```
> mlt ls -w
```

**For complex applications**

While for simple programs that may spawn a couple of child processes, for more complex processes like
GUI applications that may spawn lots of child processes, you'll have to change how Multask searches for child processes.
This takes up a very small amount of extra CPU usage, but to get the most thorough mode of searching, while using the `create`,
`start`, `restart` or `edit` commands, you can specify the `-s` flag and set its value to `deep`.

```
> mlt start 1 -s deep
```

You can change this back to `shallow` to disable deep searching.

### Stats

A way to keep track of a task's settings is the stats table. To view it, simply add the `-s` flag onto `mlt ls`:

```
> mlt ls -s
```

And the table shows:
```
+----+--------------+-----------+-------------+-------------+-------------+------------+
| id | memory limit | cpu limit | autorestart | interactive | run on boot | monitoring |
+----+--------------+-----------+-------------+-------------+-------------+------------+
| 1  | 2 GB         | 20%       | No          | No          | Yes         | shallow    |
+----+--------------+-----------+-------------+-------------+-------------+------------+
```
* `memory limit` the memory limit applied to the task's process.
* `cpu limit` the cpu limit applied to the task's process.
* `autorestart` whether the task will restart after it's finished (See more [here](/advanced-features?id=autorestart-tasks)).
* `interactive` if the task pulls and runs all of the `.rc` files before starting (See more [here](/advanced-features?id=aliasedcustom-commands)).
* `run on boot` will the task run on machine startup (See more [here](/advanced-features?id=run-on-startup)).
* `monitoring` how thorough the task is looking for potential child processes, `shallow` is the default, `deep` is for thorough searching.

## Limiting

Multask can also limit the resources each task uses.

To do this, in any of the `create`, `start`, `restart` and `edit`
commands, you can specify the `-c` or `-m` flag to set the CPU usage as a percentage, or the memory usage respectively.

Here I'm setting each process in task 1 to only use 20% of the cpu and 2 gigabytes of RAM.

```
> mlt edit 1 -c 20 -m 2G
```

To remove these limits, set the values to `none`:

```
> mlt edit 1 -c none -m none
```

