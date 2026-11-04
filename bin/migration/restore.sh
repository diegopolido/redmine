#!/usr/bin/env bash
# Restores the old server's backup into the new VPS (Kamal deployment).
#
# Usage: bin/migration/restore.sh <redmine.sql[.gz]> <redmine-files.tar.gz>
#
# Prerequisites: config/deploy.yml has the real IP, .env.production is filled in and
# `bin/kamal setup` has run once (app image + db accessory on the server).
#
# Steps (all idempotent — safe to re-run with the same or a newer backup):
#   1. make sure the `db` accessory is running and ready
#   2. upload the dump and the attachments archive
#   3. stop the app
#   4. drop/recreate the `redmine` database and import the dump
#   5. replace the attachments volume contents (owner uid 1000, 644/755)
#   6. run core + plugin migrations (5.0 -> 7.0)
#   7. clear cache and invalidate old sessions
#   8. boot the app again behind kamal-proxy
set -euo pipefail
cd "$(dirname "$0")/../.."

KAMAL=bin/kamal
DB_CONTAINER=redmine-db       # <service>-<accessory>
DB_NAME=redmine
DB_USER=redmine
FILES_VOLUME=redmine_files    # see `volumes:` in config/deploy.yml
APP_UID=1000                  # `rails` user in the Dockerfile
REMOTE_DIR=/var/tmp/redmine-migration

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $0 <redmine.sql[.gz]> <redmine-files.tar.gz>"
DUMP=$1
FILES_TAR=$2
[ -f "$DUMP" ]      || die "dump not found: $DUMP"
[ -f "$FILES_TAR" ] || die "files archive not found: $FILES_TAR"
.kamal/hooks/pre-connect || die "secrets incomplete (see .env.production / .env.production.example)."
gzip -t "$FILES_TAR" 2>/dev/null || die "$FILES_TAR is not a valid .tar.gz"
case "$DUMP" in
  *.gz) gzip -t "$DUMP" || die "$DUMP is not a valid gzip file"; DUMP_CAT="gunzip -c" ;;
  *)    DUMP_CAT="cat" ;;
esac

# Target host and SSH user come from the Kamal config (single source of truth).
read -r SSH_USER HOST < <($KAMAL config | ruby -ryaml -e '
  c = YAML.unsafe_load($stdin.read); puts "#{c[:ssh_options][:user]} #{c[:primary_host]}"')
[[ "$HOST" != *"<<"* ]] || die "fill in <<IP_DA_VPS>> in config/deploy.yml first."
TARGET="$SSH_USER@$HOST"
remote() { ssh -o BatchMode=yes "$TARGET" "$@"; }
# mysql as root inside the accessory; the password never leaves the server.
remote_mysql() { remote "docker exec -i $DB_CONTAINER sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" exec mysql -uroot $*'"; }

step "Target: $TARGET"
remote true || die "cannot ssh to $TARGET"
remote "docker volume inspect $FILES_VOLUME >/dev/null 2>&1" \
  || die "volume $FILES_VOLUME not found on $HOST — run 'bin/kamal setup' first."

step "1/8 Ensuring the db accessory is running"
if [ "$(remote "docker inspect -f '{{.State.Running}}' $DB_CONTAINER 2>/dev/null" || true)" != "true" ]; then
  $KAMAL accessory boot db
fi
for i in $(seq 1 60); do
  if remote "docker exec $DB_CONTAINER sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysqladmin -uroot ping --silent'" >/dev/null 2>&1; then
    echo "MySQL is ready."; break
  fi
  [ "$i" -eq 60 ] && die "MySQL did not become ready in time."
  sleep 2
done

step "2/8 Uploading backup to $HOST:$REMOTE_DIR"
remote "mkdir -p $REMOTE_DIR && chmod 700 $REMOTE_DIR"
scp -q -o BatchMode=yes "$DUMP" "$TARGET:$REMOTE_DIR/dump"
scp -q -o BatchMode=yes "$FILES_TAR" "$TARGET:$REMOTE_DIR/files.tar.gz"

step "3/8 Stopping the app"
$KAMAL app stop || echo "(app was not running)"

step "4/8 Recreating database '$DB_NAME' and importing the dump"
remote_mysql <<SQL
DROP DATABASE IF EXISTS \`$DB_NAME\`;
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
SQL
remote "$DUMP_CAT $REMOTE_DIR/dump | docker exec -i $DB_CONTAINER sh -c 'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" exec mysql -uroot --default-character-set=utf8mb4 $DB_NAME'"
remote_mysql -N <<SQL
SELECT CONCAT(COUNT(*), ' tables imported') FROM information_schema.tables WHERE table_schema='$DB_NAME';
SQL

step "5/8 Restoring attachments into volume $FILES_VOLUME"
remote "docker run --rm -v $FILES_VOLUME:/data -v $REMOTE_DIR:/in:ro busybox:stable sh -euc '
  find /data -mindepth 1 -delete
  tar -xzf /in/files.tar.gz -C /data
  chown -R $APP_UID:$APP_UID /data
  find /data -type d -exec chmod 755 {} +
  find /data -type f -exec chmod 644 {} +
  echo \"\$(find /data -type f | wc -l) files restored\"'"

step "6/8 Running migrations (core + plugins)"
$KAMAL app exec "bundle exec rake db:migrate redmine:plugins:migrate"

step "7/8 Clearing cache and invalidating old sessions"
$KAMAL app exec "bin/rails runner bin/migration/post_restore.rb"

step "8/8 Booting the app"
$KAMAL app boot

step "Cleaning up uploaded files on $HOST"
remote "rm -rf $REMOTE_DIR"

APP_HOST=$(ruby -ryaml -e 'puts YAML.unsafe_load(File.read("config/deploy.yml")).dig("proxy", "host")')
step "Done. Check https://$APP_HOST/ (login, an issue with attachments, the Agile board)."
