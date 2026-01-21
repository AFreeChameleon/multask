#!/bin/bash

run_migrations() {
    if ! loc="$(type -p "mlt")" || [[ -z $loc ]]; then
        echo "mlt not found, not running migrations."
        return
    fi
    versions_list=(v0.4.1 v0.4.2 v0.5.0 v0.5.1)
    local version=$(mlt -v | awk 'NF>1{print $NF}')
    echo "Current version: $version"

    local idx=-1
    for i in "${!versions_list[@]}"; do
        if [[ "${versions_list[$i]}" == "${version}" ]]; then
            idx=$i
        fi
    done

    for v in "${versions_list[@]:$idx+1}"; do
        echo "Checking for migrations for version: $v"
        {
            curl -L "https://raw.githubusercontent.com/AFreeChameleon/multask/refs/heads/master/docs/_install/migration/$v/linux.sh" -s | /bin/bash
            echo "Completed migration for $v"
        } || {
            echo "No migrations found for $v"
        }
    done
}

run_migrations
