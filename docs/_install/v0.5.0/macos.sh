#!/bin/bash

curl -L "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/tags/v0.5.0/docs/_install/migration/check_migrations.sh" -s | /bin/bash

mkdir -p $HOME/.multi-tasker/bin

if [ "$(uname -m)" = "x86_64" ]; then
    curl -L https://github.com/AFreeChameleon/multask/releases/download/v0.5.0/multask-macos_x86.tar.gz -s -o $PWD/mlt.tar.gz
elif [ "$(uname -m)" = "arm64" ]; then
    curl -L https://github.com/AFreeChameleon/multask/releases/download/v0.5.0/multask-macos_arm.tar.gz -s -o $PWD/mlt.tar.gz
fi
tar xvfz $PWD/mlt.tar.gz > /dev/null
mkdir -p $HOME/.local/bin
mv $PWD/mlt $HOME/.local/bin
rm $PWD/mlt.tar.gz

echo "Multask installed! To use multask, add this to your .rc file: export PATH=\"\$PATH:$HOME/.local/bin\""
