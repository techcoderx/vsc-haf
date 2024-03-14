#!/bin/sh

RUN_ONCE=0
SCHEMA_NAME=vsc_app

print_help () {
    cat <<EOF
Usage: $0 [OPTION[=VALUE]]...

Updates the latest Git commit hash of vsc-eco/vsc-node GitHub repository.
OPTIONS:
    --postgres-url=URL      Specify a PostgreSQL URL (required)
    --api-key=API_KEY       Specify GitHub API Key for querying vsc-eco/vsc-node repo
    --run-once              Run this script once and exit immediately
    --help,-h,-?            Displays this help message
EOF
}

if [ $# -eq 0 ]; then
    print_help
    exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --postgres-url=*)
        PSQL_URL="${1#*=}"
        ;;
    --api-key=*)
        VSC_HAF_GITHUB_API_KEY="${1#*=}"
        ;;
    --schema=*)
        SCHEMA_NAME="${1#*=}"
        ;;
    --run-once)
        RUN_ONCE=1
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

if [ -z "${PSQL_URL}" ]; then
    echo "Error: --postgres-url is required"
    print_help
    exit 1
elif [ -z "${VSC_HAF_GITHUB_API_KEY}" ]; then
    echo "Error: --api-key is required"
    print_help
    exit 1
fi

query_commit() {
    COMMIT=$(curl -s -H "Authorization: token ${VSC_HAF_GITHUB_API_KEY}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/vsc-eco/vsc-node/commits\?per_page=1 | jq -r '.[0].sha')
    psql $PSQL_URL -c "SELECT ${SCHEMA_NAME}.set_vsc_node_git_hash(FORMAT('%s', '$COMMIT'));"
}

while true; do
    query_commit
    if [ $RUN_ONCE -eq 1 ]; then
        exit 0
    fi
    sleep 300
done