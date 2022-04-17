#!/bin/bash

source .pgp-verifyrc
mirrors_fn="mirrors.txt"
signed_out_fn="signed_mirrors.txt"
keyserver_output_fn="keyserver_output.txt"
gpg_options="--homedir $keyring_folder --no-default-keyring" 
signed_by_authority=0
custom_mirrors=""


###############################################
## Functions
###############################################

# Remove all temporary files if they exist.
function cleanTemporaryFiles () {
    if [[ $keep_temporary_files -ne 1 ]]; then
        [[ -e ./$mirrors_fn && $custom_mirrors == "" ]] && rm ./$mirrors_fn
        [[ -e ./$signed_out_fn ]] && rm ./$signed_out_fn
        [[ -e ./$keyserver_output_fn ]] && rm ./$keyserver_output_fn
    fi
}

function cleanArchiveFiles () {
    [[ -d ./$keyring_folder ]] && rm -r ./$keyring_folder
    [[ -e ./$dnl_database_fn ]] && rm ./$dnl_database_fn
    [[ -e ./$pf_database_fn ]] && rm ./$pf_database_fn
    [[ -d ./$download_dir ]] && rm -r ./$download_dir
}

function usageMessage () {
    echo -e "pgp-verify.sh (PGP-Verify)\nLicense: MIT License <https://opensource.org/licenses/MIT>"
    echo -e "This is free software: you are free to change and redistribute it."
    echo -e "There is NO WARRANTY, to the extent permitted by law.\n"
    echo -e "Usage: ${0##*/} [options] <url>"
    echo -e "Verifies that the url inserted is trusted by a number of independent key authorities in order to avoid phishing attacks.\n"
    echo -e "Options:\n"
    echo -e " -i,\t--input <file path>\t\tSpecify PGP-signed mirrors file."
    echo -e " -t,\t--connection-timeout <num>\tSet time to wait before giving up connecting to keyserver."
    echo -e " -k,\t--keep-files\t\t\tKeep temporary files produced by output."
    echo -e ""
}

# Exit with usage message.
function errorExit () {
    if [[ $# -gt 0 ]]; then
        echo -e "$1" >&2
    else
        echo -e "ERROR: Invalid input for '${0##*/}'\n"
        usageMessage
    fi
    cleanTemporaryFiles
    exit 1
}

# Curl download url in first argument to file in second.
function downloadFile () {
    local url=$1
    local out_fn=$2
    local response=$(curl $curl_options -H "$curl_headers" -o "./$out_fn" -w "%{content_type}, %{http_code}" "$url")

    local ctype=$(echo $response | sed -E "s/^([a-z\/]*)[;]? .*$/\1/")
    local http_code=$(echo $response | sed -E "s/.*, ([0-9]{3})$/\1/")

    echo -n "$response"
}

# Corrects the scheme of an url. If the url is a onion url, it adds the http scheme.
# If the url contains no scheme, assume https.
function correctScheme() {
    local url=$1
    local scheme=$(echo $url | sed -n -E "s/^([a-z]+)[:]+\/[\/]+.*$/\1/p")
    local url_path=$(echo "$url" | sed -nE "s/^(([a-z]+)[:]+\/[\/]+)?(.*)$/\3/p")
    local domain=$(echo $url_path | sed -nE "s/^([^\/]*)(\/.*)?$/\1/p")
    if [[ $scheme =~ ^[h]+[t]+[p]+[s]+$ ]]; then
        local scheme="https"
    elif [[ $scheme =~ ^[h]+[t]+[p]+$ ]]; then
        local scheme="http"
    elif [[ $domain =~ ^[a-z2-7]{0,56}\.onion$ ]]; then
        local scheme="http"
    elif [[ $scheme == "" ]]; then
        local scheme="https"
    fi
    echo -n "$scheme://$url_path"
}

function correctDomainURL() {
    local url=$(correctScheme $1)
    local domain_url=$(echo $url | sed -nE "s/^(([a-z]+:\/\/)?[a-zA-Z0-9\.\-]*)(\/.*)?$/\1/p")
    echo -n "$domain_url"
}

# First argument is the fingerprint to be checked.
# Second argument is the keyring file name
# Returns user ID of key with fingerprint in keyring.
function fprToUID () {
    local fingerprint=$1
    local keyring_fn=$2

    gpg $gpg_options --keyring ./$keyring_folder/$keyring_fn --with-colons --fingerprint $fingerprint 2>&1 | sed -nE "0,/uid/{s/^uid:([^:]*:){8}([^:]*):.*$/\2/p}"
}

# First argument is filename of the file that contains mirrors.
# Second argument is filename of the keyring file.
# Writes [OK] and return 0 if mirrors file signed with key in keyring, and [ X], 1 if not.
function signedByKeyring () {
    local mirrors_fn=$1
    local keyring_fn=$2

    local good_sign=$(gpg $gpg_options --keyring ./$keyring_folder/$keyring_fn --verify ./$mirrors_fn 2>&1 | sed -nE "/Good signature/p")

    if [[ $good_sign != "" ]]; then
        [[ $verbose -eq 1 ]] && echo -e $ok
        signed_by_authority=$(( signed_by_authority+1 ))
        return 0
    else
        [[ $verbose -eq 1 ]] && echo -e $no
        return 1
    fi
}

# First argument is the fingerprint
# Returns correctly formatted list of urls found signed with this fingerprint
# in the dnl database
function onionsFromFingerprint () {
    local fingerprint=$1

    local urls=( $(grep "$fingerprint" ./$dnl_database_fn | sed -nE "s/^.*\"([a-z2-7]{1,56}\.onion)\".*$/\1/p") )
    for i in ${!urls[@]}; do
        urls[$i]=$(correctDomainURL ${urls[$i]})
    done
    echo ${urls[@]}
}


###############################################
## Parsing command line arguments
###############################################

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input)
            custom_mirrors="$2"
            shift
            shift
            ;;
        -t|--connection-timeout)
            time_limit=$2
            shift
            shift
            ;;
        -k|--keep-files)
            keep_temporary_files=1
            shift
            ;;
        -s|--silent|--quiet)
            verbose=0
            shift
            ;;
        -w|--wipe)
            keep_temporary_files=0
            cleanTemporaryFiles
            cleanArchiveFiles
            [[ $verbose -eq 1 ]] && echo -e "Wiped all temporary files."
            exit 0
            shift
            ;;
        -*|--*)
            echo "ERROR: Unknown option $1"
            errorExit
            ;;
        *)
            POS_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POS_ARGS[@]}"


###############################################
## Checking for databases and keyrings
###############################################

# If the pgp.fail database or keyring is missing.
if [[ ! -e ./$pf_database_fn || ! -e ./$keyring_folder/$pgpfail_keyring_fn ]]; then
    echo -n "Can't find pgp.fail data. Run 'update-pgpfail-keyring.sh' to re-download database and keyring? (y/n) "
    read ans
    if [[ $ans =~ [yY] ]]; then
        echo -e "\n---------------------------------------------------------------------------"
        ./update-pgpfail-keyring.sh
        echo -e "---------------------------------------------------------------------------\n"
    fi
fi

# Checking if dnl database or keyring is missing
if [[ ! -e ./$dnl_database_fn || ! -e ./$keyring_folder/$dnl_keyring_fn ]]; then
    echo -n "Can't find DNL data. Run 'update-dnl-keyring.sh' to re-download database and keyring? (y/n) "
    read ans
    if [[ $ans =~ [yY] ]]; then
        echo -e "\n---------------------------------------------------------------------------"
        ./update-dnl-keyring.sh
        echo -e "---------------------------------------------------------------------------\n"
    fi
fi


###############################################
## Retrieving mirrors
###############################################

# Find last argument
validation_url=${@: -1}

# Check if input is a valid url and try to download the mirrors file at its
# location unless a custom mirrors file has been selected.
if [[ $validation_url =~ ^([h]+[t]+[p]+[s]*[:]+\/[\/]+)?([a-zA-Z0-9\.\-]+|[a-z2-7]{56}\.onion|[a-z2-7]{16}\.onion)(\/[a-zA-Z0-9\/\.:_&=\?%\+,;@\-]*)?$ ]]; then
    validation_url=$(correctScheme $validation_url)
    if [[ $custom_mirrors == "" ]]; then
        response=$(downloadFile "$validation_url" "./$mirrors_fn")
        ctype=$(echo $response | sed -nE "s/^([a-z]*\/[a-z]*)[;,]? .*$/\1/p")
        http_code=$(echo $response | sed -nE "s/.*, ([0-9]{3})$/\1/p")
        [[ $verbose -eq 1 ]] && echo "Website returned $ctype, $http_code".
        if [[ $http_code == "200" ]]; then
            chmod 600 $mirrors_fn
        else
            errorExit
        fi
    elif [[ -e $custom_mirrors ]]; then
        mirrors_fn=$custom_mirrors
        ctype="text/plain"
    else
        errorExit
    fi
else
    errorExit
fi

validation_domain_url=$(correctDomainURL $validation_url)

# Remove HTML tags if present.
if [[ $ctype == "text/html" ]]; then
    echo -e "Warning: HTML file encountered. Will try to interpret signature by removing HTML tags."
    sed -i -E "s/<[^>]*>//g" ./$mirrors_fn
fi

# Extract only signed message of file.
[[ -e ./$signed_out_fn ]] && rm ./$signed_out_fn
gpg_error=$(gpg $gpg_options --output ./$signed_out_fn --verify ./$mirrors_fn 2>&1 | sed -nE "/no valid OpenPGP data found/p")
if [[ $gpg_error != "" ]]; then
    [[ $custom_mirrors != "" ]] && errorExit "ERROR: Could not find any PGP-signed content in file $mirrors_fn"
    errorExit "ERROR: Could not find any PGP-signed content of file retrieved from \n > $validation_url."
fi

# Create a list of all urls contained in the signed message.
links=$(cat ./$signed_out_fn | sed -nE "s/^[ ]*([a-z2-7]{56}\.onion|[a-z2-7]{16}\.onion|([h]+[t]+[p]+[s]*[:]+\/[\/]+)?[A-Za-z0-9\.\-]+)(\/[a-zA-Z0-9\/\.:_&=\?%\+,;@\-]*)?[ ]*$/\1/p")


###############################################
## Checking that input url is in mirrors list
###############################################

domain_urls=()
validation_url_index=-1

# Search through list of urls in mirrors file to see if the domain of the url is
# contained within.
validation_url_in_list=0
i=0
for link in $links
do
    url=$(correctDomainURL $link)
    if [[ $validation_domain_url == $url ]]; then
        validation_url_in_list=1
        validation_url_index=$i
    fi
    domain_urls+=( "$url" )
    i=$(( i+1 ))
done

if [[ $verbose -eq 1 ]]; then
    echo -en "URL in list of mirrors:\t\t"
    if [[ $validation_url_in_list -eq 1 ]]; then
        echo -e "$ok"
    else
        echo -e "$no"
    fi
fi



###############################################
## Processing pgp.fail
###############################################

sign_fingerprint=$(gpg $gpg_options --verify ./$mirrors_fn 2>&1 | sed -n -E 's/^.* ([0-9A-Z]{40})$/\1/p')
user_ID=""
pf_IDs=()
user_ID_DNL=""
onion_url=""


# Checking pgp.fail keyring
[[ $verbose -eq 1 ]] && echo -en "Signing key on pgp.fail:\t"
signedByKeyring $mirrors_fn $pgpfail_keyring_fn
if [[ $? -eq 0 ]]; then
    user_ID=$(fprToUID $sign_fingerprint $pgpfail_keyring_fn)
    pf_IDs=( $(grep $sign_fingerprint ./$pf_database_fn | sed -nE "s/^\"([^\"]*)\".*$/\1/p") ) 
fi

###############################################
## Processing darknetlive
###############################################

# Checking dnl keyring
[[ $verbose -eq 1 ]] && echo -en "Signing key on darknetlive:\t"
signedByKeyring $mirrors_fn $dnl_keyring_fn
if [[ $? -eq 0 ]]; then
    user_ID_DNL=$(fprToUID $sign_fingerprint $dnl_keyring_fn)

    # Find .onion url corresponding to fingerprint in dnl_database
    dnl_onions=( $(onionsFromFingerprint $sign_fingerprint) )

    echo -en "DNL url in mirrors list:\t"
    # Checking if any of the onions are included in the list of mirrors.
    found_included=0
    included_dnl_index=0
    for i in ${!dnl_onions[@]}; do
        for url in ${domain_urls[@]}; do
            #echo -e "Checking\n${dnl_onions[$i]}\n$url"
            if [[ "$url" == "${dnl_onions[$i]}" ]]; then
                found_included=$(( found_included+1 ))
                included_dnl_index=$i
            fi
        done
    done
    if [[ $found_included -gt 0 ]]; then
        onion_url=${dnl_onions[$included_dnl_index]}
        echo -e $ok
    else
        echo -e $no
    fi
fi

# TODO: Use fpr to lookup website on dnl_database. Then use the corresponding .onion site
# if it exists and see that it is included in the mirrors list.

if [[ $user_ID_DNL != "" && $user_ID != "" ]]; then
    if [[ $user_ID_DNL != $user_ID ]]; then
        [[ $verbose -eq 1 ]] && echo -e "Warning: User IDs returned from darknetlive and pgp.fail differ.\nDarknetlive has:\t\t\t$user_ID_DNL"
    fi
elif [[ $user_ID == "" ]]; then
    user_ID=$user_ID_DNL
fi

###############################################
## Checking openpgp keyserver
###############################################

echo "keyserver hkp://zkaan2xfbuxia2wpf7ofnkbz6r5zdbbvxbunvp5g2iebopbfc4iqmbad.onion" > ./$keyring_folder/$gpg_fn
timeout --preserve-status ${time_limit}s gpg $gpg_options --keyring ./$keyring_folder/$openpgp_keyring_fn --options ./$keyring_folder/$gpg_fn --auto-key-locate keyserver --recv-keys $sign_fingerprint &> ./$keyserver_output_fn
ret_status=$?
[[ $verbose -eq 1 ]] && echo -en "Signing key on openpgp:\t\t"
if [[ $ret_status -eq 0 ]]; then
    was_skipped=$(cat ./$keyserver_output_fn | sed -nE "/skipped/p")
    if [[ $was_skipped == "" ]]; then
        signedByKeyring $mirrors_fn $openpgp_keyring_fn
    else
        echo -e "$partially:\tExists, but without a corresponding User ID. Could therefore not check signature."
    fi
else
    echo -e $no
fi



###############################################
## Printing results and exit
###############################################

if [[ $verbose -eq 1 ]]; then
    echo -e "\n---------------------------------------------------------------------------"
    echo -e "Key fingerprint:\t$sign_fingerprint"
    [[ $user_ID != "" ]] && echo -e "User ID:\t\t$user_ID"
    if [[ $onion_url != "" ]]; then
        echo -e "DNL URL:"
        if [[ $validation_domain_url == $onion_url ]]; then
            echo -e " > \033[1m$onion_url\033[0m"
        else
            echo -e " - $onion_url"
        fi
    fi

    # Printing names associated with the key fingerprint on pgp.fail
    if [[ ${#pf_IDs[@]} -gt 0 ]]; then
        echo -e "PGP.fail identities:"
        for ID in ${pf_IDs[@]}; do
            echo -e " - $ID"
        done
    fi

    echo -e "All signed mirrors:"
    for i in ${!domain_urls[@]}; do
        if [[ $i -eq $validation_url_index ]]; then
            echo -e " > \033[1m${domain_urls[$i]}\033[0m"
        else
            echo -e " - ${domain_urls[$i]}"
        fi
    done
    echo -e "---------------------------------------------------------------------------\n"
fi

echo -en "Valid URL:\t\t\t"
if [[ $validation_url_in_list -eq 1 && $signed_by_authority -gt 0 ]]; then
    echo -e "$ok: $signed_by_authority/3"
else
    echo -e $no
fi

cleanTemporaryFiles
exit 0

