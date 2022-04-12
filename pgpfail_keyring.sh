#!/bin/bash

source .pgp-verifyrc

html_fn="pgp_fail.html"
key_authority_url="http://pgpfail4gnkxlxf6ij76quyafrlwwzouoht5tsp7wa3qt37enbnjluad.onion"
key_authority_url_regex=$(echo $key_authority_url | sed -E 's/\//\\\//g')
urls_fn="urls.txt"

gpg_options="--no-default-keyring --keyring ./$keyring_folder/$pgpfail_keyring_fn --homedir ./$keyring_folder"

# Setup keyring file-structure.

if [[ ! -d ./$keyring_folder ]]; then
    mkdir $keyring_folder
    chmod 700 $keyring_folder
fi
if [[ ! -e ./$keyring_folder/$pgpfail_keyring_fn ]]; then
    gpg $gpg_options --fingerprint
fi



#######################################################
## Get all urls to pgp.txt files
#######################################################

if [[ ! -e $html_fn || $use_old_downloads -ne 1 ]]; then
    curl $curl_options -o $html_fn $key_authority_url
fi
# Extracts urls from html that are after the first <h3>..</h3> pair.
# Outputs one url pr. line in file $urls_fn
cat $html_fn | perl -0777 -ne 'print $1 if /<h3>[^<]*<\/h3>(.*?)<h3>/s' | sed -n -E "s/^<a href=\"([^\"]*)\".*$/${key_authority_url_regex}\/\1/p" > $urls_fn

# Convert file with urls into a bash arrays of urls and separate
# urls pointing to .txt and .html files.

pgp_urls=()
html_urls=()

while IFS= read -r url; do
    escaped_url=$(echo $url | sed -E "s/ /%20/g")
    if [[ $escaped_url =~ ^.*\.txt$ ]]; then
        pgp_urls+=( "$escaped_url" )
    elif [[ $escaped_url =~ ^.*\.html$ ]]; then
        html_urls+=( "$escaped_url" )
    fi
done < "$urls_fn"


#######################################################
## Go through .html files to get remaining pgp.txt urls
#######################################################

[[ $verbose -eq 1 ]] && echo -e "Finding mirror-signing-key urls in sub-directories."

for html_url in ${html_urls[@]}; do
    html_sub_root="${html_url%/*}"
    # Only obtain keys used for signing mirrors.
    pgp_sub_url=$(curl $curl_options $html_url | sed -nE "s/<a href=\"([^\"]*\.txt)\"[^<]*<--- Mirrors.*$/\1/p" | sed -E "s/ /%20/g")
    # Only add url to array if it is non-zero and ends in ".txt"
    if [[ $pgp_sub_url =~ ^[^\.]*.txt$ ]]; then
        pgp_urls+=( "$html_sub_root/$pgp_sub_url" )
    else
        echo -e "Warning: Could not find mirror signing key url @ $html_url"
    fi
done


#######################################################
## Download all keys and import them into keyring
#######################################################

[[ $verbose -eq 1 ]] && echo -e "Downloading '.txt' files to '$download_dir' from \n$key_authority_url,\nand importing their keys to local keyring at './$keyring_folder/'."

[[ ! -d ./$download_dir ]] && mkdir ./$download_dir

# Function for downloading and importing public keys into keyring. Takes
# an integer that is assumed to be the index in the bash array pgp_urls as
# only argument.
function processPGP() {
    download_file_path="./$download_dir/tmp_pf_pgp$1.asc"
    url=${pgp_urls[$1]}
    if [[ ! -e $download_file_path || $use_old_downloads -ne 1 ]]; then
        curl $curl_options -o $download_file_path "$url"
    fi
    if [[ $(file $download_file_path) =~ "PGP public key block" ]]; then
        gpg $gpg_options -q --import-options keep-ownertrust --import $download_file_path
    else
        echo "Warning: $url did not return a valid public key."
    fi
}

# Download the pgp files and import them all in parallell.
for i in ${!pgp_urls[@]}; do
    processPGP $i & 
done
wait

# Remove temporary files
if [[ $keep_downloads -ne 1 ]]; then
    rm -r ./$download_dir
    rm $html_fn
fi

num_imported_keys=$(gpg $gpg_options --list-keys | sed -nE "/^pub/p" | wc -l)
[[ $verbose -eq 1 ]] && echo "$num_imported_keys public keys imported into keyring database."

exit 0
