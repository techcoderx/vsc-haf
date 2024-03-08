#!/bin/sh
set -e

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"

TAG=latest

print_help () {
    cat <<EOF
Usage: $0 [OPTION[=VALUE]]...

Builds the Docker images.
OPTIONS:
    --tag=TAG               The image tag to use (default: latest)
    --help,-h,-?            Displays this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*)
        TAG="${1#*=}"
        ;;
    --help|-h|-?)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        echo
        print_help
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid argument"
        echo
        print_help
        exit 2
        ;;
    esac
    shift
done

echo Building the images with tag $TAG...
docker build -t vsc-haf:$TAG -f $SCRIPTPATH/../Dockerfile .
docker build -t vsc-haf/gh-fh:$TAG -f $SCRIPTPATH/../Dockerfile.gh_fh .