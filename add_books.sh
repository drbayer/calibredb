#!/bin/bash
# Requires bash version >= 4.0


# Log script errors
script_error() {
    lineno=$1
    errcode=$2
    message="$0: Error code $errcode encountered in script on line $lineno"
    log error $message
}

trap 'script_error ${LINENO} $? ' ERR


# Set variable default values. These can be changed with either
# command line flags or with the appropriate environment variables
USERNAME="${CALIBREDB_USERNAME:=calibredb}"
PASSWORD="${CALIBREDB_PASSWORD:=supersecret}"
LOGLEVEL="${CALIBREDB_LOGLEVEL:=DEBUG}"
ADDBOOKS_DIR="${CALIBREDB_CONSUMPTION_DIR:=/addbooks}"
LIBRARY="${CALIBREDB_LIBRARY:=/books}"
TIME_FORMAT="${CALIBREDB_TIME_FORMAT:=%Y-%m-%dT%H:%M:%S%z}"


usage() {
    echo "Usage: ${0##*/} -d -l -L -p -u"
    echo
    echo "    -d DIR         Directory to monitor for new files. Default: /addbooks"
    echo "    -l LOGLEVEL    loglevel. Default: DEBUG"
    echo "    -L LIBRARY     Library location. Default: /books"
    echo "    -t TIMEFORMAT  Timestamp format (strftime). Default: ISO_8601 (%Y-%m-%dT%H:%M:%S%z)."
    echo "    -p PASSWORD    Calibre DB password. Default: calibredb"
    echo "    -u USERNAME    Calibre DB username. Default: supersecret"
    echo
    exit 5
}


log() {
    local message_level="$(echo $1 | tr '[a-z]' '[A-Z]')"
    local message="$2"

    declare -A log_levels=(
        [DEBUG]=0
        [INFO]=1
        [WARN]=2
        [ERROR]=3
    )

    if [[ ${log_levels[$message_level]} -ge ${log_levels[$LOGLEVEL]} ]]; then
        >&2 printf "%s %s [%s] %s\n" "$(timestamp)" "$message_level" "${FUNCNAME[1]}" "$message"
    fi
}


timestamp() {
    timestamp=$(date +"$TIME_FORMAT")
    echo $timestamp
}


init_db() {
    local db=$LIBRARY
    result="$(calibredb --with-library="$db" --username="$USERNAME" --password="$PASSWORD" list 2>&1)"
    log debug "$result"
    result="$(calibredb --with-library="$db" --username="$USERNAME" --password="$PASSWORD" add_custom_column --is-multiple source_filename "Source Filename" text 2>&1)"
    log debug "$result"
}


get_library_db() {
    local db=$LIBRARY

    if [[ ! -d "$db" ]]; then
        log warn "Unable to locate calibre database file."
        return 255
    fi

    db_file=${db}/metadata.db
    if [[ ! -f "${db_file}" ]]; then
        log debug "Calibre database not found. Initializing new database at $db."
        init_db
    fi

    if [[ -f "${db_file}" ]]; then
        log debug "Found calibre database file: $db_file"
        echo "$db_file"
    else
        log warn "Unable to initialize calibre database."
        return 255
    fi
}


wait_for_file() {
    local file="$1"

    local time=5      # seconds to wait
    local size_a=0
    local size_b=1
    while [[ $size_a -ne $size_b ]]; do
        log debug "Waiting ${time} seconds for transfer to complete"
        size_a=$(ls -l "${file}" | awk '{print $5}')
        sleep $time
        size_b=$(ls -l "${file}" | awk '{print $5}')
    done
}


get_title() {
    local file="$1"
    local book_title=""

    # perform comparison on title only because that the field least likely to be missing

    # metadata field for title is sometimes "Title" and sometimes "BookName"
    book_title="$(exiftool -s3 -Title "$file")"
    [[ -z $book_title ]] && book_title="$(exiftool -s3 -BookName "$file")"

    # still no title? use filename instead
    if [[ -z $book_title ]]; then
        book_title=${file##/*/}
        book_title="${book_title%%.*}"
        log debug "Title not found in metadata for '$file'. Using filename instead."
    else
        log debug "Found title '$book_title' in metadata for '$file'"
    fi
    echo "$book_title"
}


search_source_filename() {
    # At this time there doesn't appear to be a way to search custom columns using the calibredb cli.
    # This is my ugly hack to get around that problem.
    local book_id=
    local db=$(get_library_db)
    local file="${1##/*/}"

    # strip file extension so we can search for alternate formats
    file="${file%.*}"

    if [[ -z $db ]]; then
        log error "Unable to locate calibre database."
        return -1
    fi

    local source_filename_table=custom_column_$(sqlite3 $db "SELECT id FROM custom_columns WHERE label = 'source_filename'")
    local sql="SELECT DISTINCT b.id FROM books_${source_filename_table}_link bc
         INNER JOIN books b on bc.book = b.id
         INNER JOIN ${source_filename_table} c on bc.value = c.id
         WHERE c.value LIKE '${file}.%';"

    book_id=$(sqlite3 $db "$sql")
    if [[ -z $book_id ]]; then
        log info "Book ID not found for '$file'"
        book_id=
    fi

    if [[ "$book_id" =~ , ]]; then
        log error "Multiple book IDs found for file '$file'. Book IDs found: $book_id."
        book_id=
    fi

    echo $book_id
}


add_source_filename() {
    local file="${1##/*/}"
    local book_id=$(get_book_id "$1")
    local db=$(get_library_db)

    if [[ -z $db ]]; then
        log error "Unable to locate calibre database."
        return -1
    fi

    # make sure we haven't already added this file to source_filename
    local source_filename_table=custom_column_$(sqlite3 $db "SELECT id FROM custom_columns WHERE label = 'source_filename'")
    local sql="SELECT COUNT(*) FROM books_${source_filename_table}_link bc
        INNER JOIN ${source_filename_table} c ON bc.value = c.id
        WHERE bc.book = $book_id
        AND c.value = '$file';"

    found=$(sqlite3 $db "$sql")
    if [[ $found -eq 0 ]]; then
        local result="$(calibredb --with-library=$LIBRARY --username="$USERNAME" --password="$PASSWORD" set_custom -a source_filename $book_id "${file##/*/}" 2>&1)"
        log info "$result"
    else
        log info "${file} already found in source_filename for book ID $book_id. Not adding source_filename."
    fi
}


get_book_id() {
    local file="$1"

    local book_title="$(get_title "$file")"
    local book_id=

    if [[ ! -z "$book_title" ]]; then
        # calibredb search returns items that match all the words in the search string instead of the literal string
        # as a result we have to do this really hacky filtered list/jq selection
        book_id="$(calibredb --with-library="$LIBRARY" --username="$USERNAME" --password="$PASSWORD" list -s "$book_title" -f id,title --for-machine \
            | TITLE="$book_title" jq '.[] | select(.title == env.TITLE) | .id' \
            | paste -sd, -)"

        if [[ -z $book_id ]]; then
            log debug "Title '$book_title' not found in calibre db. Checking source_filename."
            book_id=$(search_source_filename "$file")
        fi

        if [[ $book_id =~ , ]]; then
            log error "Multiple book IDs found for book $book_title"
            book_id=
        fi

        if [[ $book_id && ${book_id+x} ]]; then
            log debug "Title '$book_title' found in calibre db with ID $book_id"
        else
            log debug "Title '$book_title' not found in calibre db."
        fi
    fi

    echo $book_id
}


add_book() {
    local file="$1"

    log info "Adding book '$file' to Calibre library"
    local result="$(calibredb --with-library=$LIBRARY --username="$USERNAME" --password="$PASSWORD" add "$file" 2>&1)"
    log info "$result"

    if [[ "$result" =~ "Added book id" ]]; then
        if [[ "${file#*.}" == "pdf" ]]; then
            fix_pdf "$file"
        fi
        add_source_filename "$file"
        rm "$file"
    else
        log error "Error adding ${file} to calibredb. Leaving file on filesystem for future processing."
    fi
}


add_format() {
    local file="$1"

    log info "Adding new format for '$file' to Calibre library"

    local book_id=$(get_book_id "$file")
    local result="$(calibredb --with-library=$LIBRARY --username="$USERNAME" --password="$PASSWORD" add_format --dont-replace ${book_id} "${file}" 2>&1)"

    if [[ -z $result ]]; then
        add_source_filename "$file"
        log info "Finished adding new format of '$file' to Calibre library"
        rm "$file"
    else
        log warn "$result"
        log info "Leaving '$file' on filesystem for future processing."
    fi
}


fix_pdf() {
    local file="$1"
    local basename="${file##*/}"
    local book_title="$(echo "${basename%%.*}" | tr '_' ' ')" # strip extension and replace '_' with ' ' because calibre does that
    local title=
    local author=
    local result=

    log info "Cleaning up metadata for '$book_title'"
    local book_id="$(calibredb --with-library=$LIBRARY --username="$USERNAME" --password="$PASSWORD" search title:"$book_title" 2>&1)"

    if [[ $book_id =~ ^[0-9]+$ ]]; then
        log debug "Found book_id for '$book_title': $book_id"
        title="$(exiftool -s3 -Title "$file")"
        # PDFs may use author or creator for author metadata
        author="$(exiftool -s3 -Author "$file")"
        [[ -z $author ]] && author="$(exiftool -s3 -Creator "$file")"
    else
        log error "Book id not found for '$book_title': $book_id"
    fi

    if [[ $title && ${title+x} ]]; then
        log info "Updating title metadata for $file"
        result="$(calibredb --with-library=$LIBRARY --username="$USERNAME" --password="$PASSWORD" set_metadata -f title:"$title" -f sort:"$title" $book_id 2>&1)"
        log info "$result"
    fi

    if [[ $author && ${author+x} ]]; then
        log info "Updating author metadata for $file"
        result="$(calibredb --with-library=$LIBRARY --username="$USERNAME" --password="$PASSWORD" set_metadata -f authors:"$author" $book_id 2>&1)"
        log info "$result"
    fi
}


# main
while getopts u:p:l:d:t:h FLAG; do
    case $FLAG in
        u)  USERNAME=$OPTARG
            ;;
        p)  PASSWORD=$OPTARG
            ;;
        l)  LOGLEVEL=$OPTARG
            ;;
        d)  ADDBOOKS_DIR=$OPTARG
            ;;
        t)  TIME_FORMAT=$OPTARG
            ;;
        *)  usage
            ;;
    esac
done


db=$(get_library_db)
if [[ -z $db ]]; then
    log error "Unable to locate or initialize calibre database. Exiting script."
    exit 255
fi

log info "Setting up watcher for incoming files"
inotifywait -m $ADDBOOKS_DIR -e create -e moved_to -q |
    while read dir action file; do
        book_file="${dir}${file}"
        log info "Detected incoming book '${book_file}'"
        wait_for_file "${book_file}"

        book_id=$(get_book_id "${book_file}")

        if [[ -z $book_id ]]; then
            log debug "Unable to find book id for $book_file. Adding new book."
            add_book "${book_file}"
        else
            log debug "Found book id $book_id. Adding new book format."
            add_format "${book_file}"
        fi
        log info "Processing complete for '${book_file}'"
    done

