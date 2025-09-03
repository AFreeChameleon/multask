# Advanced Features
## Environment variables

Multask creates tasks with the environment variables in your terminal's current
session. If you want to update an existing task with new environment variables
in your session, include the -e flag in either the start or restart commands.

```
> mlt start 1 -e
```

## Process monitoring
Some commands you want to run may be quite complex such as ones that spawn GUIs,
and Multask's default way of searching for processes belonging to a task may
not be able to pick it up, thinking the task has finished while it's still running.

To fix this Multask has a mode that uses a tiny bit more CPU for a more thorough
search for processes created by a task. It's the `-M` flag you can set to either
`deep` or `shallow`.

The default is `shallow`.

```
> mlt start 1 -M deep
```

## Interactive mode (UNIX)
When running a task in either Macos or Linux, it uses a basic shell which means
you can't use aliased commands in your .rc files. This is for performance, but
passing in the -i flag runs your .rc files before running the command. Making it
so the task will recognise any aliased commands set in your .rc files when you
open your session.

```
> mlt start 1 -i
```

## Resource limiting
I mentioned this earlier in the documentation, but for very intensive processes
spawned from tasks, you can allocate how much CPU and memory each process is
allowed to take up by passing in the -c or -m flags respectfully.

In this command, I'm setting it so each process spawned can only use 20% of the
CPU and 2 gigabytes of memory.

```
> mlt start 1 -c 20 -m 2G
```
