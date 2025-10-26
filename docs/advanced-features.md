# Advanced Features

## Environment variables

A lot of commands and programs rely on your session's environment variables.

Whenever a new task is ran, Multask takes a snapshot of your current session's environment variables
and plugs them into the command that is about to be ran. And every time that task is ran through `start` or `restart`,
it keeps the same environment variables.

To update the environment variables being given to the task, when writing out
the `start` or `restart` commands, include the `-e` flag which takes another
snapshot of your environment and plugs that into the task, replacing the previous snapshot.

```
> mlt start 1 -e
```

## Aliased/Custom commands

In Unix, some commands you want to run are actually ones that only exist after your `.rc`
file has been parsed for example:

```
In your .bashrc file:

test_function() {
    echo "This is a test function"
    echo "that only exists after source .bashrc"
    echo "has been run"
}

alias tf="test_function"
```

By default, being able to run these functions or aliased commands are disabled
because the overhead of parsing .rc files can get quite large, so to enable it, either in the
`create`, `start`, `restart` or `edit` commands, you can add a `-i` flag which reads your .rc files
and allows you to run those commands.

```
> mlt start 1 -i
```

To disable this, use the `-I` flag instead.

## Autorestart tasks

Some tasks may need to keep restarting such as web servers that need to connect
to a database that may take a while to start.

Autorestarting just restarts the task after the process finishes (but stops completely if
using `mlt stop`). To make your task autorestart, use the `-p` flag in the `create`, `start`, `restart` or `edit`
commands.

```
> mlt start 1 -p
```

After the task stops, it will retry after 2 seconds.

To disable autorestarting, use the `-P` flag instead.

## Namespaces

While you can refer to tasks by their task id:

```
> mlt start 1 2 3 4
```

Or if you want to start every task, you can just put `all`:

```
> mlt start all
```

You can refer to multiple tasks by using a namespace. To do this, in the `create`
or `edit` commands, add the `-n` flag with a value that is letters only:

```
> mlt edit 1 2 -n web
```

And now you can refer to tasks 1 and 2 by their namespace:

```
> mlt start web
```

## Run on startup

Tasks can be ran on startup, to do this either in the `create` or `edit` commands by add the `-b` flag.

```
> mlt edit 1 -b
```

And now after booting up the machine, it'll automatically run that task.

To disable starting up on boot, use the `-B` flag.
