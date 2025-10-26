#!/bin/bash

echo "Upgrading from 0.4.2 to 0.5.0"

last_index_of_str() {
    local str="$1"
    local sub="$2"

    # Remove everything up to the last occurrence of the substring
    local after=${str##*"$sub"}

    # If substring not found, return -1
    if [[ "$after" == "$str" ]]; then
        echo -1
        return
    fi

    # Remove the tail to get everything before the last occurrence
    local before=${str%"$after"}

    # Calculate index (0-based)
    local index=$(( ${#before} - ${#sub} ))
    echo "$index"
}

for dir in $HOME/.multi-tasker/tasks/*/; do
    path="${dir}stats.json"
    stats=$(cat $path)
    extra_vals=""
    if ! [[ "$stats" == *\"interactive\":* ]]; then
        extra_vals+=",\"interactive\":false"
    fi
    if ! [[ "$stats" == *\"boot\":* ]]; then
        extra_vals+=",\"boot\":false"
    fi
    idx=$(last_index_of_str "$stats" "}")
    if (( idx == -1 )); then
        continue
    fi
    new="${stats:0:idx}${extra_vals}${stats:idx}"
    echo $new > $path
done

echo "Upgraded to v0.5.0"
