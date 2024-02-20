#!/bin/bash

PSQL_URL=$1
VSC_HAF_GITHUB_API_KEY=$2

COMMIT=$(curl -s -H "Authorization: token ${VSC_HAF_GITHUB_API_KEY}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/vsc-eco/vsc-node/commits\?per_page=1 | jq -r '.[0].sha')

psql $1 -c "SELECT vsc_app.set_vsc_node_git_hash(FORMAT('%s', '$COMMIT'));"