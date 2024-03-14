#!/bin/sh
set -xe

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"

DEFAULT_API_SCHEMA_NAME=vsc_api
DEFAULT_SCHEMA_NAME=vsc_app
DEFAULT_APP_CONTEXT_NAME=vsc_app

API_SCHEMA_NAME=$DEFAULT_API_SCHEMA_NAME
SCHEMA_NAME=$DEFAULT_SCHEMA_NAME
APP_CONTEXT_NAME=$DEFAULT_APP_CONTEXT_NAME

print_help () {
    cat <<EOF
Usage: $0 [OPTION[=VALUE]]...

Copies PostgreSQL scripts into dist folder with speficied schema and app context name.
OPTIONS:
    --schema=SCHEMA                 The schema name to use (default: vsc_app)
    --api-schema=SCHEMA             The API schema name to use (default: vsc_api)
    --app-context=CONTEXT_NAME      HAF app context name to use (default: vsc_app)
    --help,-h,-?                    Displays this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --schema=*)
        SCHEMA_NAME="${1#*=}"
        ;;
    --api-schema=*)
        API_SCHEMA_NAME="${1#*=}"
        ;;
    --app-context=*)
        APP_CONTEXT_NAME="${1#*=}"
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

DESTINATION_PATH=$SCRIPTPATH/../dist
SED_COMMAND=sed

cp -r $SCRIPTPATH/../src/sql $DESTINATION_PATH

if [[ $(uname) -eq "Darwin" ]]; then
    SED_COMMAND=gsed
fi

# Rename app context
if [[ "$APP_CONTEXT_NAME" != "$DEFAULT_APP_CONTEXT_NAME" ]]; then
    ${SED_COMMAND} -i "s/${DEFAULT_APP_CONTEXT_NAME}_/${APP_CONTEXT_NAME}_/g" $DESTINATION_PATH/sql/*.sql
    ${SED_COMMAND} -i "s/const APP_CONTEXT = '${DEFAULT_APP_CONTEXT_NAME}/const APP_CONTEXT = '${APP_CONTEXT_NAME}/g" $DESTINATION_PATH/constants.js
fi

# Rename schema
if [[ "$SCHEMA_NAME" != "$DEFAULT_SCHEMA_NAME" ]]; then
    ${SED_COMMAND} -i "s/${DEFAULT_SCHEMA_NAME}\./${SCHEMA_NAME}\./g" $DESTINATION_PATH/sql/*.sql
    ${SED_COMMAND} -i "s/${DEFAULT_SCHEMA_NAME};/${SCHEMA_NAME};/g" $DESTINATION_PATH/sql/*.sql
    ${SED_COMMAND} -i "s/${DEFAULT_SCHEMA_NAME} /${SCHEMA_NAME} /g" $DESTINATION_PATH/sql/*.sql
    ${SED_COMMAND} -i "s/const SCHEMA_NAME = '${DEFAULT_SCHEMA_NAME}/const SCHEMA_NAME = '${SCHEMA_NAME}/g" $DESTINATION_PATH/constants.js
fi

# Rename API schema
if [[ "$API_SCHEMA_NAME" != "$DEFAULT_API_SCHEMA_NAME" ]]; then
    ${SED_COMMAND} -i "s/${DEFAULT_API_SCHEMA_NAME}\./${API_SCHEMA_NAME}\./g" $DESTINATION_PATH/sql/*.sql
    ${SED_COMMAND} -i "s/${DEFAULT_API_SCHEMA_NAME};/${API_SCHEMA_NAME};/g" $DESTINATION_PATH/sql/*.sql
    ${SED_COMMAND} -i "s/${DEFAULT_API_SCHEMA_NAME} /${API_SCHEMA_NAME} /g" $DESTINATION_PATH/sql/*.sql
fi