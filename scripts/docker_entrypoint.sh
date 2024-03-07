#! /bin/sh
set -e
cd /app

if [ "$1" = "install_app" ]; then
  shift
  exec su - haf_admin -c "/app/scripts/install_app.sh --host=\"${POSTGRES_HOST:-haf}\""
elif [ "$1" = "process_blocks" ]; then
  shift
  exec su - vsc_owner -c "pnpm start \"$@\""
elif [ "$1" = "uninstall_app" ]; then
  shift
  exec su - haf_admin -c "/app/scripts/uninstall_app.sh --host=\"${POSTGRES_HOST:-haf}\" --user=\"${POSTGRES_USER:-haf_admin}\""
else
  echo "usage: $0 install_app|process_blocks|uninstall_app"
  exit 1
fi