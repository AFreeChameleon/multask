# Installation

To install Multask, run the command under your respective operating system.

Bash & ZSH officially supported.

## Linux
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/linux.sh" | bash
```

## Mac
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/macos.sh" | bash
```

## Windows
```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/win.ps1|iex"
```

## FreeBSD (outdated)

Multask's newest version is currently not supporting FreeBSD. So in the meantime the older version can still be used. [here](https://github.com/AFreeChameleon/multask/releases/tag/v0.2.0)

## Source

To build from source, you need:

- Zig compiler version 0.14.0 [here](https://ziglang.org/download/#release-0.14.0)
- Git [here](https://git-scm.com/downloads)

### Creating folders
**Unix:** If you don't have the `~/.local/bin` directory, create it and add it to the `$PATH` in your .rc file:
```
> mkdir -p $HOME/.local/bin
```

**Windows:** Create a `.multi-tasker` folder in your %USERPROFILE% and create a `bin` folder inside of it:
```
> powershell -c 'New-Item "$env:USERPROFILE\.multi-tasker\bin\ " -ItemType Directory -Force | Out-Null'
```

### Installing the executable
Next, clone the repo and go inside it:
```
> git clone https://github.com/AFreeChameleon/multask && cd multask
```

And to build it, just run:

**Unix**
```
> zig build -Doptimize=ReleaseSmall --prefix-exe-dir $HOME/.local/bin/
```

**Windows**
```
> powershell -c 'zig build -Doptimize=ReleaseSmall --prefix-exe-dir "$env:USERPROFILE\.multi-tasker\bin\ "'
```
And you also need to add `%USERPROFILE%\.multi-tasker\bin` to the Path environment variable.

Or you could move the `mlt` executable into a directory which works for you.

**Optimisations**

The different options for the `-Doptimize` flag are:

- `ReleaseSmall`
- `ReleaseFast`
- `ReleaseSafe`
- `Debug`

To understand what the different build modes mean, check it out [here](https://zig.guide/build-system/build-modes/)

## Updating

To update your Multask version, simply run the installation script with the version you want to update to and
it will automatically migrate your data to the newer version.
