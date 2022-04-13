#!/bin/bash

source .pgp-verifyrc
mirrors_fn="mirrors.txt"
sign_out_fn="signed_mirrors.txt"
keyserver_output_fn="keyserver_output.txt"
gpg_options="--homedir $keyring_folder --no-default-keyring" 
signed_by_authority=0


###############################################
## Functions
###############################################

# Remove all temporary files if they exist.
function cleanTemporaryFiles () {
    [[ -e ./$mirrors_fn ]] && rm ./$mirrors_fn
    [[ -e ./$signed_out_fn ]] && rm ./$sign_out_fn
    [[ -e ./$keyserver_output_fn ]] && rm ./$keyserver_output_fn
}

# Exit with usage message.
function errorExit () {
    if [[ $# -gt 0 ]]; then
        echo -e "$1" >&2
    else
        echo -e "ERROR: '${0##*/}' needs an argument containing a valid url on the form\n:~$ ${0##*/} [-ceiklnps] http[s]://[xxx.]xxxxxxxxx.xxxx" >&2
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
## Retriving mirrors
###############################################

# Find last argument
validation_url=${@: -1}

# Check if input is a valid url
if [[ $validation_url =~ ^([h]+[t]+[p]+[s]*[:]+\/[\/]+)?([a-zA-Z0-9\.\-\/]*|[a-z2-7]{56}\.onion(\/.*)?|[a-z2-7]{16}\.onion(\/.*)?)$ ]]; then
    validation_url=$(correctScheme $validation_url)
    response=$(downloadFile "$validation_url" "./$mirrors_fn")
    ctype=$(echo $response | sed -nE "s/^([a-z]*\/[a-z]*)[;,]? .*$/\1/p")
    http_code=$(echo $response | sed -nE "s/.*, ([0-9]{3})$/\1/p")
    if [[ $http_code == "200" ]]; then
        chmod 600 $mirrors_fn
    else
        errorExit
    fi
else
    errorExit
fi

[[ $verbose -eq 1 ]] && echo "Website returned $ctype, $http_code".
validation_domain_url=$(correctDomainURL $validation_url)

# Remove HTML tags if present.
if [[ $ctype == "text/html" ]]; then
    echo -e "Warning: HTML file retrived. Will try to interpret signature by removing HTML tags."
    sed -i -E "s/<[^>]*>//g" ./$mirrors_fn
fi

# Extract only signed message of file.
gpg_error=$(gpg $gpg_options --output ./$sign_out_fn --verify ./$mirrors_fn 2>&1 | sed -nE "/no valid OpenPGP data found/p")
if [[ $gpg_error != "" ]]; then
    errorExit "ERROR: Could not find any PGP-signed content if file retrieved from \n > $validation_url."
fi

# Create a list of all urls contained in the signed message.
links=$(cat ./$sign_out_fn | sed -nE "s/(^([a-z2-7]{56}\.onion|[a-z2-7]{16}\.onion|[h]+[t]+[p]+[s]*[:]+\/[\/]+[^\/><\" ]*)|^.*[^a-z0-9]([a-z2-7]{56}\.onion|[a-z2-7]{16}\.onion|[h]+[t]+[p]+[s]*[:]+\/[\/]+[^\/<>\" ]*)).*$/\2\3/p")


###############################################
## Checking that input url is in mirrors list
###############################################

urls=()
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
    urls+=( "$url" )
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
user_ID_DNL=""
onion_url=""


# Checking pgp.fail keyring
[[ $verbose -eq 1 ]] && echo -en "Signing key on pgp.fail:\t"
signedByKeyring $mirrors_fn $pgpfail_keyring_fn
if [[ $? -eq 0 ]]; then
    user_ID=$(fprToUID $sign_fingerprint $pgpfail_keyring_fn)
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
        for url in ${urls[@]}; do
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
gpg $gpg_options --keyring ./$keyring_folder/$openpgp_keyring_fn --options ./$keyring_folder/$gpg_fn --auto-key-locate keyserver --recv-keys $sign_fingerprint &> ./$keyserver_output_fn
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
    [[ $onion_url != "" ]] && echo -e "DNL URL:\t\t$onion_url"

    echo -e "All signed mirrors:"
    for i in ${!urls[@]}; do
        if [[ $i -eq $validation_url_index ]]; then
            echo -e " > \033[1m${urls[$i]}\033[0m"
        else
            echo -e " - ${urls[$i]}"
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

