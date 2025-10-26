#!/bin/bash

mkdir -p $HOME/.multi-tasker/bin
curl -L https://github.com/AFreeChameleon/multask/releases/download/v0.4.2/multask-linux.tar.gz -s -o $PWD/mlt.tar.gz
tar xvfz $PWD/mlt.tar.gz > /dev/null
mkdir -p $HOME/.local/bin
mv $PWD/mlt $HOME/.local/bin
rm $PWD/mlt.tar.gz

echo "Multask installed! Run mlt -h for options on how to use it."
