<div align="center">
  <a href="https://afreechameleon.github.io/multask/">
    <img src="https://github.com/AFreeChameleon/multask/blob/master/docs/_media/gecko.png?raw=true" alt="Logo" width="150" height="150">
  </a>

  <h1 align="center">Multask</h1>

  <p align="center">
    A process manager for Linux, Mac, Windows & FreeBSD to simplify your developer environment.
  </p>
  <p align="center">
    See the
    <a href="https://afreechameleon.github.io/multask/#/">documentation</a>
    for more details.
  </p>
  <p align="center">
    Designed to organise projects which need processes running at the same time with flexible resource limits for scaling.
  </p>
  <p align="center">
    <a href="https://www.youtube.com/watch?v=KVUPj4636hE" target="_blank">Watch the demo</a>
  </p>
  <a href="https://www.youtube.com/watch?v=KVUPj4636hE" target="_blank">
    <img src="https://img.youtube.com/vi/KVUPj4636hE/0.jpg" alt="Demo video">
  </a>
</div>

## Installation & Functions

See the [documentation](https://afreechameleon.github.io/multask/#/installation) for more details.

## Running tests

NOTE: DO NOT RUN THESE TESTS LOCALLY - they delete your tasks at the moment, this will be fixed in the next release but for now this is just meant to be run from the github actions.

To run the zig unit tests, you need zig version 0.14.0 and run `zig build test --summary all`.

To run the simulation tests in ruby, you'll need ruby version 3.4.4 and run:
```
bundle install
bundle exec rspec
```

## License

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Flute is under the GPL v3 license.
