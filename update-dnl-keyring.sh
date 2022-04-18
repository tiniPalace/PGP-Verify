#!/bin/bash

source .pgp-verifyrc

key_authority_url="http://darkzzx4avcsuofgfez5zq75cqc4mprjvfqywo45dfcaxrwqg6qrlfid.onion/onions/"
key_authority_url_regex=$(echo $key_authority_url | sed -E 's/\//\\\//g')

gpg_options="--no-default-keyring --keyring ./$keyring_folder/$dnl_keyring_fn --homedir ./$keyring_folder"

html_fn="darknetlive.html"
html_filtered_fn="darknetlive_filtered.html"
urls_fn="temp_urls.txt"


###############################################
## Parsing command line arguments
###############################################

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--use-downloads)
            use_old_downloads=1
            shift
            ;;
        -k|--keep-downloads)
            keep_downloads=1
            shift
            ;;
        -s|--silent|--quiet)
            verbose=0
            shift
            ;;
        -p|--port)
            port_number=$2
            curl_options="-s -x socks5h://localhost:$port_number --connect-timeout $time_limit"
            shift
            shift
            ;;
        -t|--time-limit)
            time_limit=$2
            curl_options="-s -x socks5h://localhost:$port_number --connect-timeout $time_limit"
            shift
            shift
            ;;
        -*|--*)
            echo "ERROR: Unknown option $1"
            exit 1
            ;;
        *)
            POS_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POS_ARGS[@]}"


#######################################################
## Parse DNL site for pgp files.
#######################################################

# Only download html file when needed.
if [[ ! -e $html_fn || $use_old_downloads -ne 1 ]]; then
    [[ $verbose -eq 1 ]] && echo "Downloading main html file"
    curl $curl_options -H "$curl_headers" http://darkzzx4avcsuofgfez5zq75cqc4mprjvfqywo45dfcaxrwqg6qrlfid.onion/onions/ > $html_fn

    [[ $verbose -eq 1 ]] && echo "Filtering file for valid links and building internal arrays."
    # Filter out section containing urls
    sed -i -E "s/<article/\n<article/g" $html_fn
    sed -i -E "s/section>/section>\n/g" $html_fn
fi

cat $html_fn | perl -0777 -ne 'print $1 if /Personal blogs published by random internet people\.<\/li><\/ol><section class="a95 a4p n__d">(.*?)<\/section/s' > $html_filtered_fn
num_articles=$(cat $html_filtered_fn | wc -l)

[[ $verbose -eq 1 ]] && echo "Found $num_articles number of links in html."

# Filter out names, v3 onion urls and pgp links for sites with pgp
cat $html_filtered_fn | sed -nE 's/^<article[^>]*><ul[^>]*><li><h2[^>]*><a[^>]*>([^<]*)<\/a><\/h2><\/li><ul[^>]*><li[^>]*><span[^>]*>(([0-9a-z]){1,56}\.onion)<\/span>.*<a [^ ]* href=([^ ]*) [^>]*>pgp<\/a>.*$/\1<->\2<->\4/p' > $urls_fn
num_filtered_entries=$(cat "$urls_fn" | wc -l)

[[ $verbose -eq 1 ]] && echo "Of these $num_filtered_entries contained both a valid onion address and a PGP key."

# Build arrays from lines

names=()
pgp_urls=()
onion_urls=()

while IFS= read -r line; do
    name=$(echo $line | sed -nE "s/^([^<]*)<->.*$/\1/p")
    onion_url=$(echo $line | sed -nE "s/^[^<]*<->([^<]*)<->.*$/\1/p" | sed -E "s/ /%20/g")
    pgp_url=$(echo $line | sed -nE "s/^[^<]*<->[^<]*<->(.*)$/\1/p" | sed -E "s/ /%20/g")
    names+=( "$name" )
    onion_urls+=( "$onion_url" )
    pgp_urls+=( "$pgp_url" )
done < "$urls_fn"

rm $urls_fn
rm $html_filtered_fn

num_pgp_urls=${#pgp_urls[@]}
if [[ $num_pgp_urls -ne $num_filtered_entries || $num_pgp_urls -ne ${#names[@]} || $num_pgp_urls -ne ${#onion_urls[@]} ]]; then
    echo -e "\nERROR: Problem creating arrays from $num_filtered_entries filtered urls. Num of entries\npgp_urls: $num_pgp_urls, names: ${#names[@]}, onion_urls: ${#onion_urls[@]}"
    exit 1
fi

#######################################################
## Download public keys
#######################################################

[[ $verbose -eq 1 ]] && echo -e "Downloading PGP keys as .txt files to './$download_dir/' if needed."

[[ ! -d ./$download_dir ]] && mkdir ./$download_dir

# Function for downloading. Takes
# an integer that is assumed to be the index in the bash array pgp_urls as
# only argument.
function processPGP() {
    download_file_path="./$download_dir/tmp_dnl_pgp$1.asc"
    url=${pgp_urls[$1]}
    if [[ ! -e $download_file_path || $use_old_downloads -ne 1 ]]; then
        curl $curl_options -H "$curl_headers" -o $download_file_path "$url"
    fi
}

# Download the pgp files all in parallell.
for i in ${!pgp_urls[@]}; do
    processPGP $i & 
done
wait

[[ $verbose -eq 1 ]] && echo -e "Download complete."

#######################################################
## Build keyring and database file
#######################################################

[[ $verbose -eq 1 ]] && echo -e "\nGenerating keyring and database based on downloaded PGP keys."

[[ -e ./$dnl_database_fn ]] && mv ./$dnl_database_fn "./${dnl_database_fn}_backup"
echo -n "" > ./$dnl_database_fn

# Setup keyring file-structure.

if [[ ! -d ./$keyring_folder ]]; then
    mkdir $keyring_folder
    chmod 700 $keyring_folder
fi
if [[ ! -e ./$keyring_folder/$dnl_keyring_fn ]]; then
    gpg $gpg_options --fingerprint
fi

for i in ${!pgp_urls[@]}; do
    url=${pgp_urls[$i]}
    name=${names[$i]}
    onion_url=${onion_urls[$i]}
    download_file_path="./$download_dir/tmp_dnl_pgp$i.asc"
    key_output=$(gpg --with-fingerprint --with-colons --show-keys $download_file_path 2> gpg_err)
    error=$(< gpg_err)
    rm gpg_err
    if [[ $error == "" ]]; then
        fingerprints=$(echo "$key_output" | sed -nE "/pub/,/uid/{s/^fpr[:]+([A-F0-9]*)[:]+$/\1/p}")
        first_fprint=$(echo "$key_output" | sed -nE "0,/uid/{s/^fpr[:]*([0-9A-F]*)[:]*$/\1/p}")
        f_print_num=$(echo $fingerprints | wc -w)
        first_uid=$(echo "$key_output" | sed -nE "0,/uid/{s/^uid:([^:]*:){8}([^:]*):.*$/\2/p}")
        if [[ $first_fprint =~ ^[A-F0-9]{40}$ ]]; then

            if [[ $f_print_num -gt 1 && $verbose -eq 1 ]]; then
                echo "Warning: .txt of $name contains multiple keys for User IDs" >&2
                echo "$key_output" | sed -nE "s/^uid:[oidreqnmfu\-]*:[0-9]*:[0-9]*:[A-F0-9]*:[0-9]*:[0-9]*:[0-9A-F]*:[a-z\-]*:([^:]+):.*$/\1/p" | sed -E "s/^/\t\- /g" >&2
                echo "Only the first will be used in database" >&2
            fi
            gpg $gpg_options -q --import-options keep-ownertrust --import $download_file_path
            gpg_return=$?
            # Only add url to database if the key was successfully imported to the gpg keyring.
            if [[ $gpg_return -eq 0 ]]; then
                echo "\"$name\",\"$onion_url\",\"$first_uid\",\"$first_fprint\"" >> ./$dnl_database_fn
            elif [[ $verbose -eq 1 ]]; then
                echo -e "ERROR entry $i: gpg returned error-code $gpg_return.\n$name not added to database." >&2
                gpg $gpg_options --import-options keep-ownertrust --import $download_file_path
            fi

        else
            echo "Warning: Entry $i: $url did not return a valid public key."
        fi
    elif [[ $verbose -eq 1 ]]; then
        echo -e "ERROR importing from\n\t$name @ $url\nnow located in file $download_file_path." >&2
        echo -e "GPG returned error:\n\t${error}\nskipping." >&2
    fi
done

#######################################################
## Clean up and report results
#######################################################

num_keys_in_keyring=$(gpg $gpg_options --list-keys | sed -nE "/^pub/p" | wc -l)
num_keys_in_database=$(cat ./$dnl_database_fn | wc -l)

# Remove backup database if everything was successful
[[ $num_keys_in_database -gt 0 && -e "./${dnl_database_fn}_backup" ]] && rm "./${dnl_database_fn}_backup"
if [[ $keep_downloads -ne 1 ]]; then
    rm -r ./$download_dir
    echo "Cleaned up downloads at './$download_dir/'"
fi

[[ $verbose -eq 1 ]] && echo -e "\nSuccessfully generated keyring containing $num_keys_in_keyring keys, and database containing $num_keys_in_database urls"

exit 0
