#!/bin/bash

mkdir -p $HOME/.multi-tasker/bin
curl https://afreechameleon.github.io/files/mlt.tar.gz -s -o $PWD/mlt.tar.gz
tar xvfz $PWD/mlt.tar.gz
mv $PWD/mlt $HOME/.multi-tasker/bin
rm $PWD/mlt.tar.gz
for f in $HOME/.*rc
do
    if ! grep -q "export PATH=\"\$PATH:$HOME/.multi-tasker/bin\"" $f
    then
        echo "export PATH=\"\$PATH:$HOME/.multi-tasker/bin\"" >> $f
    fi
done

echo "To use mlt in this session, run: export PATH=\"\$PATH:$HOME/.multi-tasker/bin\""
