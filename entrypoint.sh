#!/bin/sh

set -e

if [ "$1" = "calibredb" ]; then
    # Run default container processes

    exec /opt/calibre/bin/add_books.sh

else
    # Run command specified at run-time

    exec "$@"

fi

