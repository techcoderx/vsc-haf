#!/bin/sh
set -e

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"

TAG=latest
BUILD_ARGS=""
GH_FH="false"

print_help () {
    cat <<EOF
Usage: $0 [OPTION[=VALUE]]...

Builds the Docker images.
OPTIONS:
    --tag=TAG                       The image tag to use (default: latest)
    --schema=SCHEMA                 The schema name to use (default: vsc_app)
    --api-schema=SCHEMA             The API schema name to use (default: vsc_api)
    --app-context=CONTEXT_NAME      HAF app context name to use (default: vsc_app)
    --test-schema                   Shortcut of --schema=vsc_test --api-schema=vsc_tapi --app-context=vsc_test
    --plain-output                  Uses --progress=plain arg in Docker build command
    --gh-fh                         Builds the gh-fh image
    --help,-h,-?                    Displays this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*)
        TAG="${1#*=}"
        ;;
    --test-schema)
        BUILD_ARGS="$BUILD_ARGS --build-arg SCHEMA_NAME=vsc_test --build-arg API_SCHEMA_NAME=vsc_tapi --build-arg APP_CONTEXT=vsc_test"
        ;;
    --schema=*)
        BUILD_ARGS="$BUILD_ARGS --build-arg SCHEMA_NAME=${1#*=}"
        ;;
    --api-schema=*)
        BUILD_ARGS="$BUILD_ARGS --build-arg API_SCHEMA_NAME=${1#*=}"
        ;;
    --app-context=*)
        BUILD_ARGS="$BUILD_ARGS --build-arg APP_CONTEXT=${1#*=}"
        ;;
    --plain-output)
        BUILD_ARGS="$BUILD_ARGS --progress=plain"
        ;;
    --gh-fh)
        GH_FH="true"
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

if [ -n "$BUILD_ARGS" ]; then
    echo Build args: $BUILD_ARGS
fi

docker build -t vsc-haf:$TAG $BUILD_ARGS -f $SCRIPTPATH/../Dockerfile .

if [ $GH_FH = "true" ]; then
    docker build -t vsc-haf/gh-fh:$TAG -f $SCRIPTPATH/../Dockerfile.gh_fh .
fi