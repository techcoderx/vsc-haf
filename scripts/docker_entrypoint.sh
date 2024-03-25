#! /bin/sh
set -e
cd /app

if [ "$1" = "install_app" ]; then
  shift
  exec su - haf_admin -c "/app/scripts/install_app.sh --host=\"${POSTGRES_HOST:-haf}\""
elif [ "$1" = "process_blocks" ]; then
  shift
  date --utc -I'seconds' > /tmp/block_processing_startup_time.txt
  exec su - vsc_owner -c "cd /app; pnpm start --log-level=\"${VSC_HAF_LOG_LEVEL:-info}\" --postgres-url=\"${POSTGRES_URL:-postgres://vsc_owner@haf/haf_block_log}\""
elif [ "$1" = "subindexer" ]; then
  shift
  exec su - vsc_owner -c "cd /app; pnpm run subindexer --log-level=\"${VSC_HAF_LOG_LEVEL:-info}\" --postgres-url=\"${POSTGRES_URL:-postgres://vsc_owner@haf/haf_block_log}\" --ipfs-api-url=\"${VSC_HAF_IPFS_API_URL:-http://ipfs:5001}\""
elif [ "$1" = "uninstall_app" ]; then
  shift
  exec su - haf_admin -c "/app/scripts/uninstall_app.sh --host=\"${POSTGRES_HOST:-haf}\" --user=\"${POSTGRES_USER:-haf_admin}\""
else
  echo "usage: $0 install_app|process_blocks|subindexer|uninstall_app"
  exit 1
fi