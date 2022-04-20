#!/bin/bash

# A script for making the verify-mirror command available to the command line.

# Find the location of the scripts.
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
home_dir=$(cd -- ~ &> /dev/null && pwd)

# An array containing the lines we want to inject into .bashrc in order to install the script.
lines=( "# PGP-Verify entry" "verify-mirror () {" "\tcurrent_path=\"\$(pwd)\"" "\tcd $script_dir" "\t./verify-mirror.sh \$@" "\tcd \"\$current_path\"" "}" )

# Make sure all scripts in the script folder are executable.
chmod 774 $script_dir/*.sh

# Search for .bashrc
if [[ ! -e $home_dir/.bashrc ]]; then
    echo -ne "Could not find bashrc. Create one? (y/n) "
    read ans
    if [[ $ans =~ [yY] ]]; then
        touch $home_dir/.bashrc
    else
        exit 1
    fi
fi

rc_path="$home_dir/.bashrc"

# Search for previous entry in .bashrc
prev_entry="$(grep "${lines[0]}" $rc_path)"

# If no previous entry is found, then we add verify-mirror function at the end.
if [[ $prev_entry == "" ]]; then
    for line in "${lines[@]}"; do
        echo -e "$line" >> $rc_path
    done
    echo "PGP-Verify successfully installed to $rc_path"
    source $rc_path

    # If we found a previous entry, we ask if the user want to try to remove it instead.
else
    echo -n "Previous entry found. Uninstall? (y/n) "
    read ans
    if [[ $ans =~ [yY] ]]; then
        cat -n $rc_path | sed -nE "/${lines[0]}/p" | grep "MATCHED"
        start_line=$(cat -n $rc_path | sed -nE "/# PGP-Verify entry/p" | sed -nE "s/^[ ]*([0-9]*).*$/\1/p")
        end_line=$(( start_line + ${#lines[@]} - 1 ))
        line_content="$(sed -n "${end_line}p" $rc_path)"
        if [[ $line_content =~ ^\}$ ]]; then
            sed -i "${start_line},${end_line}d" $rc_path
            echo -e "PGP-Verify successfully removed from $rc_path"
        else
            echo -e "ERROR: Corrupted install detected. Please manually delete the function following '# PGP-Verify entry' as well as that string from $rc_path" >&2
            exit 1
        fi
    fi
fi
exit 0
