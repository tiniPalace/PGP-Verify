#!/bin/bash

source .pgp-verifyrc

html_fn="pgp_fail.html"
key_authority_url="http://pgpfail4gnkxlxf6ij76quyafrlwwzouoht5tsp7wa3qt37enbnjluad.onion"
key_authority_url_regex=$(echo $key_authority_url | sed -E 's/\//\\\//g')
urls_fn="urls.txt"

gpg_options="--no-default-keyring --keyring ./$keyring_folder/$pgpfail_keyring_fn --homedir ./$keyring_folder"

#######################################################
## Functions
#######################################################

# Exit with usage message.
function errorExit () {
    if [[ $# -gt 0 ]]; then
        echo -e "$1" >&2
    else
        echo -e "ERROR: '${0##*/}' needs an argument containing a valid url on the form\n:~$ ${0##*/} [-ceiklnps] http[s]://[xxx.]xxxxxxxxx.xxxx" >&2
    fi
    exit 1
}


# Setup keyring file-structure.

if [[ ! -d ./$keyring_folder ]]; then
    mkdir $keyring_folder
    chmod 700 $keyring_folder
fi
if [[ ! -e ./$keyring_folder/$pgpfail_keyring_fn ]]; then
    gpg $gpg_options --fingerprint
fi

# Setup database file.

[[ -e ./$pf_database_fn ]] && mv ./$pf_database_fn "./${pf_database_fn}_backup"
echo -n "" > ./$pf_database_fn


#######################################################
## Get all urls to pgp.txt files
#######################################################

[[ $verbose -eq 1 ]] && echo -e "Downloading list of all PGP files."

if [[ ! -e ./$html_fn || $use_old_downloads -ne 1 ]]; then
    curl $curl_options -H "$curl_headers" -o "./$html_fn" $key_authority_url || errorExit "Could not contact key authority at url\n - $key_authority_url"
fi
# Extracts urls from html that are after the first <h3>..</h3> pair.
# Outputs one url pr. line in file $urls_fn
cat ./$html_fn | perl -0777 -ne 'print $1 if /<h3>[^<]*<\/h3>(.*?)<h3>/s' | sed -n -E "s/^<a href=\"([^\"]*)\".*$/${key_authority_url_regex}\/\1/p" > $urls_fn

# Convert file with urls into a bash arrays of urls and separate
# urls pointing to .txt and .html files.

pgp_urls=()
pgp_names=()
html_urls=()
html_names=()

while IFS= read -r url; do
    escaped_url=$(echo $url | sed -E "s/ /%20/g")
    filename=${url##*/}
    name=${filename%\.*}
    if [[ $escaped_url =~ ^.*\.txt$ ]]; then
        pgp_urls+=( "$escaped_url" )
        pgp_names+=( "$name" )
    elif [[ $escaped_url =~ ^.*\.html$ ]]; then
        html_urls+=( "$escaped_url" )
        html_names+=( "$name" )
    fi
done < "$urls_fn"


#######################################################
## Go through .html files to get remaining pgp.txt urls
#######################################################

[[ $verbose -eq 1 ]] && echo -e "Digging into the main html file to expose PGP keys hiding in subdirectories."

# First we download all the htmls in parallell
[[ ! -d ./$download_dir ]] && mkdir ./$download_dir

# First argument is the output path
# Second argument is the url
function downloadFile () {
    local download_file_path=$1
    local url=$2
    if [[ ! -e $download_file_path || $use_old_downloads -ne 1 ]]; then
        curl $curl_options -H "$curl_headers" -o $download_file_path $url
    fi
}

for i in ${!html_urls[@]}; do
    download_file_path="./$download_dir/tmp_pgpfail$i.html"
    html_url=${html_urls[$i]}
    downloadFile "$download_file_path" "$html_url" &
done
wait

# Then extract path to pgp.txt file for each html and add to pgp arrays.
for i in ${!html_urls[@]}; do
    html_url=${html_urls[$i]}
    html_sub_root="${html_url%/*}"
    download_file_path="./$download_dir/tmp_pgpfail$i.html"
    # Only obtain keys used for signing mirrors.
    pgp_sub_url=$(cat $download_file_path | sed -nE "s/<a href=\"([^\"]*\.txt)\"[^<]*<--- Mirrors.*$/\1/p" | sed -E "s/ /%20/g")
    # Only add url to array if it is non-zero and ends in ".txt"
    if [[ $pgp_sub_url =~ ^[^\.]*.txt$ ]]; then
        pgp_urls+=( "$html_sub_root/$pgp_sub_url" )
        pgp_names+=( "${html_names[$i]}" )
    else
        echo -e "Warning: Could not find mirror signing key url\n @ $html_url" >&2
    fi
done


#######################################################
## Download all keys and import them into keyring
#######################################################

[[ $verbose -eq 1 ]] && echo -e "\nCompleted building list of all key files on server.\nDownloading keys to '$download_dir/' and importing them to local keyring at '$keyring_folder/'.\nBuilding database of names and keys in '$pf_database_fn'"

# Download all pgp files in parallell.
for i in ${!pgp_urls[@]}; do
    download_file_path="./$download_dir/tmp_pf_pgp$i.asc"
    url=${pgp_urls[$i]}
    downloadFile "$download_file_path" "$url" &
done
wait


# Then import pgp files in to gpg keyring and build pgpfail database
num_imported_keys=0
for i in ${!pgp_urls[@]}; do
    download_file_path="./$download_dir/tmp_pf_pgp$i.asc"
    name=${pgp_names[$i]}
    url=${pgp_urls[$i]}
    # Use gpg to check that the file contains PGP keys.
    key_output=$(gpg --with-fingerprint --with-colons --show-keys $download_file_path 2> ./gpg_err)
    error=$(< ./gpg_err)
    rm ./gpg_err
    if [[ $error == "" ]]; then
        fingerprints=$(echo "$key_output" | sed -nE "/pub/,/uid/{s/^fpr[:]+([A-F0-9]*)[:]+$/\1/p}")
        first_fprint=$(echo "$key_output" | sed -nE "0,/uid/{s/^fpr[:]*([0-9A-F]*)[:]*$/\1/p}")
        f_print_num=$(echo $fingerprints | wc -w)
        first_uid=$(echo "$key_output" | sed -nE "0,/uid/{s/^uid:([^:]*:){8}([^:]*):.*$/\2/p}")
        if [[ $first_fprint =~ ^[A-F0-9]{40}$ ]]; then

            # At this point we can be sure the file contains a valid key. We need to check if it contains more than a single key.
            # If it contains multiple keys we import them all in the keyring, but use only the first as an entry in the database.
            if [[ $f_print_num -gt 1 && $verbose -eq 1 ]]; then
                echo "Warning: .txt of $name contains multiple keys for User IDs" >&2
                echo "$key_output" | sed -nE "s/^uid:[oidreqnmfu\-]*:[0-9]*:[0-9]*:[A-F0-9]*:[0-9]*:[0-9]*:[0-9A-F]*:[a-z\-]*:([^:]+):.*$/\1/p" | sed -E "s/^/ \- /g" >&2
                echo "Only the first will be used in database" >&2
            fi
            gpg $gpg_options -q --import-options keep-ownertrust --import $download_file_path
            gpg_return=$?
            # Only add url to database if the key was successfully imported to the gpg keyring.
            if [[ $gpg_return -eq 0 ]]; then
                num_imported_keys=$(( num_imported_keys + f_print_num ))
                echo "\"$name\",\"$first_uid\",\"$first_fprint\"" >> ./$pf_database_fn
            elif [[ $verbose -eq 1 ]]; then
                echo -e "ERROR entry $i: gpg returned error-code $gpg_return.\n$name not added to database." >&2
                gpg $gpg_options --import-options keep-ownertrust --import $download_file_path
            fi

        else
            echo "Warning: Entry $i: $url did not return a valid public key." >&2
        fi
    elif [[ $verbose -eq 1 ]]; then
        echo -e "ERROR importing from\n\t$name @ $url\nnow located in file $download_file_path." >&2
        echo -e "GPG returned error:\n\t${error}skipping." >&2
    fi
done


# Remove temporary files
rm "./$urls_fn"
if [[ $keep_downloads -ne 1 ]]; then
    rm -r ./$download_dir
    rm $html_fn
fi

num_keyring_keys=$(gpg $gpg_options --list-keys | sed -nE "/^pub/p" | wc -l)
num_db_entries=$(cat ./$pf_database_fn | wc -l)

if [[ $num_db_entries -gt 0 ]]; then
    rm "./${pf_database_fn}_backup"
fi

[[ $verbose -eq 1 ]] && echo -e "\nSuccessfully imported $num_imported_keys public keys into keyring, which now contains $num_keyring_keys keys.\nDatabase of names corresponding to the keys have $num_db_entries entries."

exit 0
