#!/bin/bash

source .pgp-verifyrc

db_fn="dnl_database.csv"
keyring_fn="dnl-keyring.kbx"

fingerprints=()

existsInKeyring () {
    fprint=$1
    exists=$(gpg --no-default-keyring --keyring ./$keyring_folder/$keyring_fn --homedir ./$keyring_folder --list-keys $fprint 2>/dev/null)
    if [[ $exists != "" ]]; then
        echo 1
    else
        echo 0
    fi

}

passed=1
while IFS= read -r line; do
    fingerprint=$(echo $line | sed -nE "s/^(\"[^\"]*\",){3}\"([^\"]*)\"$/\2/p")
    already_seen=0
    for fprint in ${fingerprints[@]}; do
        if [[ $fprint == $fingerprint ]]; then
            already_seen=1
        fi
    done
    if [[ $already_seen != 1 ]]; then
        fingerprints+=( "$fingerprint" )

        # Check that fingerprint exists in keyring
        in_keyring=$(existsInKeyring $fingerprint)
        if [[ $in_keyring -ne 1 ]]; then
            echo "Not in keyring:"
            echo -e "$line\n"
            passed=0
        fi
    fi

    # Check for duplicates of fingerprint in database
    num_db_entries=$(grep "$fingerprint" $db_fn | wc -l)
    if [[ $num_db_entries -gt 1 && $already_seen != 1 ]]; then
        echo "Found duplicate entries of fingerprint $fingerprint at"
        grep "$fingerprint" $db_fn
        echo ""
    fi

done < "$db_fn"

if [[ $passed -eq 1 ]]; then
    echo "All keys referenced in database, also exists in keyring."
fi
