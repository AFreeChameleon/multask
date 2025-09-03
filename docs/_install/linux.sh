#!/bin/bash

mkdir -p $HOME/.multi-tasker/bin
curl -L https://github.com/AFreeChameleon/multask/releases/download/v0.4.2/multask-linux.tar.gz -s -o $PWD/mlt.tar.gz
tar xvfz $PWD/mlt.tar.gz > /dev/null
mv $PWD/mlt $HOME/.multi-tasker/bin
rm $PWD/mlt.tar.gz

echo "To use multask, add this to your .rc file: export PATH=\"\$PATH:$HOME/.multi-tasker/bin\""
