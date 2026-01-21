# Installation

To install Multask, run the command under your respective operating system.

Bash & ZSH officially supported.

## Linux
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/v0.5.1/linux.sh" | bash
```

## Mac
```
curl -s "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/v0.5.1/macos.sh" | bash
```

## Windows
```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/v0.5.1/win.ps1|iex"
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
mkdir -p $HOME/.local/bin
```

**Windows:** Create a `.multi-tasker` folder in your %USERPROFILE% and create a `bin` folder inside of it:
```
powershell -c 'New-Item "$env:USERPROFILE\.multi-tasker\bin\ " -ItemType Directory -Force | Out-Null'
```

### Installing the executable
Next, clone the repo and go inside it:
```
git clone https://github.com/AFreeChameleon/multask && cd multask
```

And to build it, just run:

**Unix**
```
zig build -Doptimize=ReleaseSmall --prefix-exe-dir $HOME/.local/bin/
```

**Windows**
```
powershell -c 'zig build -Doptimize=ReleaseSmall --prefix-exe-dir "$env:USERPROFILE\.multi-tasker\bin\ "'
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

Except for Windows, you'll have to run this manually:

```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multask/refs/tags/v0.5.1/docs/_install/migration/v0.5.1/win.ps1 | iex"
```

This is because of a bug where multask can't be run in the background, it's been fixed for future releases.

## Migrations

While updating through major versions, formats of task data might be changed, while this is dealt with in an automatic process when running the install script,
to automatically check and run migrations up to a certain version you can run:

Windows
```
# Set the "v0.5.1" to whichever version you want to migrate to
powershell -c "Set-Variable -Value v0.5.1 -Name ver; irm https://raw.githubusercontent.com/AFreeChameleon/multask/refs/tags/$ver/docs/_install/migration/check_migrations.ps1 | iex"
```

Unix
```
# Set the "v0.5.1" to whichever version you want to migrate to
export MULTASK_VERSION=v0.5.1
curl -L "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/tags/$MULTASK_VERSION/docs/_install/migration/check_migrations.sh" -s | /bin/bash
```

To manually migrate your data you can run these lines:

### v0.4.2 to v0.5.1
Windows:
```
powershell -c "irm https://raw.githubusercontent.com/AFreeChameleon/multask/refs/tags/v0.5.1/docs/_install/migration/v0.5.1/win.ps1 | iex"
```
Unix:
```
curl -L "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/tags/v0.5.1/docs/_install/migration/v0.5.1/linux.sh" -s | /bin/bash
```
