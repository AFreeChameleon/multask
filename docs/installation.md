# Installation

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

Multask's newest version is currently not supporting FreeBSD. So in the meantime the older version can still be used. [here](https://github.com/AFreeChameleon/multask/releases/tag/0.20.0)

## Source

To build from source, you need the Zig compiler version 0.14.0 and to build it for production, just run:
```
> git clone https://github.com/AFreeChameleon/multask && cd multask
> zig build -Doptimize=ReleaseSmall
```

The different options for the `-Doptimize` flag are:

- `ReleaseSmall`
- `ReleaseFast`
- `ReleaseSafe`
- `Debug`

To understand what the different build modes mean, check it out [here](https://zig.guide/build-system/build-modes/)
