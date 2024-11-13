#!/bin/bash

mkdir -p $HOME/.multi-tasker/bin
curl https://github.com/AFreeChameleon/multask/releases/latest/download/multask_osx.tar.gz -s -o $PWD/multask.tar.gz
tar xvfz $PWD/multask.tar.gz > /dev/null
mv $PWD/multask/mlt $HOME/.multi-tasker/bin
rm $PWD/multask.tar.gz
rm -r $PWD/multask
if [[ $SHELL == *"zsh"* ]]; then
    rc_content=(cat $HOME/.zshrc)
    if [[ $rc_content == *"export PATH=\"\$PATH:$HOME/.multi-tasker/bin\""* ]]; then
        echo "export PATH=\"\$PATH:$HOME/.multi-tasker/bin\"" >> $HOME/.zshrc
    fi
elif [[ $SHELL == *"bash"* ]]; then
    rc_content=(cat $HOME/.bashrc)
    if [[ $rc_content == *"export PATH=\"\$PATH:$HOME/.multi-tasker/bin\""* ]]; then
        echo "export PATH=\"\$PATH:$HOME/.multi-tasker/bin\"" >> $HOME/.bashrc
    fi
elif [[ $SHELL == *"/sh"* ]]; then
    rc_content=(cat $HOME/.shrc)
    if [[ $rc_content == *"export PATH=\"\$PATH:$HOME/.multi-tasker/bin\""* ]]; then
        echo "export PATH=\"\$PATH:$HOME/.multi-tasker/bin\"" >> $HOME/.shrc
    fi
else
    echo "Shell not recognized, bash & zsh officially supported. Manual installation needed."
fi

echo "To use multask in this session, run: export PATH=\"\$PATH:$HOME/.multi-tasker/bin\""
