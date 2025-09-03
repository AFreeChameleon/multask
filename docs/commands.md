# Commands

## Create
Usage:
```
> mlt create "echo hi"
```
Can also be ran with `c`.
This creates a task from your specified command and runs it.

### Flags:
- `-m [num]` Set maximum memory limit, can be in bytes (B), kilobytes (K), megabytes (M) or Gigabytes (G)
- `-c [num]` Set maximum cpu limit by percentage, must be a number from 1 to 99
- `-n [text]` Set namespace for the task. can only include alphabetical characters
- `-i` Interactive mode (can use aliased commands on your environment)
- `-p` Persist mode (will restart after 2 seconds if the program exits)
- `-M, --monitor` How thorough looking for child processes will be, use `deep` for complex 
applications like GUIs although it can be a little more CPU intensive, `shallow` is the default

## Start
Usage:
```
> mlt start 1
```
Can also be ran with `s`.
This runs existing tasks by their task ids or namespaces.

### Flags
- `-e` Updates env variables with your current environment
- `-m [num]` Set maximum memory limit, can be in bytes (B), kilobytes (K), megabytes (M) or Gigabytes (G)
- `-c [num]` Set maximum cpu limit by percentage, must be a number from 1 to 99
- `-i` Interactive mode (can use aliased commands on your environment)
- `-p` Persist mode (will restart after 2 seconds if the program exits)
- `-M, --monitor` How thorough looking for child processes will be, use `deep` for complex 

## Stop
Usage:
```
> mlt stop 1
```
This stops tasks by their task ids or namespaces.

## Edit
Usage:
```
> mlt edit 1
```
Edits task details by their task ids or namespaces.

### Flags
- `-m [num]` Set maximum memory limit, can be in bytes (B), kilobytes (K), megabytes (M) or Gigabytes (G)
- `-c [num]` Set maximum cpu limit by percentage, must be a number from 1 to 99
- `-n [text]` Set namespace for the task. can only include alphabetical characters
- `-p` Persist mode (will restart after 2 seconds if the program exits)
- `-M, --monitor` How thorough looking for child processes will be, use `deep` for complex 

## Restart
Usage:
```
> mlt restart 1
```
This stops and starts existing tasks by their task ids or namespaces.

### Flags
- `-e` Updates env variables with your current environment
- `-m [num]` Set maximum memory limit, can be in bytes (B), kilobytes (K), megabytes (M) or Gigabytes (G)
- `-c [num]` Set maximum cpu limit by percentage, must be a number from 1 to 99
- `-i` Interactive mode (can use aliased commands on your environment)
- `-p` Persist mode (will restart after 2 seconds if the program exits)
- `-M, --monitor` How thorough looking for child processes will be, use `deep` for complex 

## Ls
Usage:
```
> mlt ls
```
Lists all tasks with data associated to it e.g memory and cpu usage.

You can also specify task ids or namespaces to only view those.

### Flags
- `-w` Updates the table every 2 seconds
- `-a` Shows all child processes each task has spawned

## Logs
Usage:
```
> mlt logs 1
```

Shows output from a task by its task id.

### Flags
- `-l [num]` See number of previous lines default is 20
- `-w, -f` Listen to new logs coming in

## Delete
Usage:
```
> mlt delete 1
```
Deletes tasks by their task ids or namespaces.

## Health
Usage:
```
> mlt health
```
Checks state of multask, run this when multask is not working.

## Help
Usage:
```
> mlt help
```
Shows list of commands to run as well as their flags.
