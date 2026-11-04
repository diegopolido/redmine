#!/usr/bin/env bash
# Manual backup of the Redmine running on the server in config/deploy.yml.
# Downloads to your machine (nothing is kept on the server):
#   redmine.pgdump        pg_dump -Fc of the `redmine` database
#   redmine-files.tar.gz  the attachments volume
#   MANIFEST.txt          versions, counts and sha256 checksums
#
# The pair restores anywhere with:
#   bin/migration/restore.sh <dir>/redmine.pgdump <dir>/redmine-files.tar.gz
# which is also how Redmine moves to another server (see DEPLOY.md).
#
# Usage: bin/backup_now.sh [output-dir]
#   default output: ~/backups/redmine/<UTC timestamp>/
set -euo pipefail
cd "$(dirname "$0")/.."

KAMAL=bin/kamal
DB_CONTAINER=redmine-db
DB_NAME=redmine
DB_USER=redmine
FILES_VOLUME=redmine_files

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

read -r SSH_USER HOST < <($KAMAL config | ruby -ryaml -e '
  c = YAML.unsafe_load($stdin.read); puts "#{c[:ssh_options][:user]} #{c[:primary_host]}"')
[[ "$HOST" != *"<<"* ]] || die "fill in <<IP_DA_VPS>> in config/deploy.yml first."
TARGET="$SSH_USER@$HOST"
remote() { ssh -o BatchMode=yes "$TARGET" "$@"; }

OUT=${1:-$HOME/backups/redmine/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
chmod 700 "$OUT"

step "Backing up $TARGET into $OUT"
remote "docker inspect -f '{{.State.Running}}' $DB_CONTAINER" 2>/dev/null | grep -q true \
  || die "$DB_CONTAINER is not running on $HOST."

step "Database dump (pg_dump -Fc)"
remote "docker exec $DB_CONTAINER pg_dump -U $DB_USER -Fc --no-owner $DB_NAME" > "$OUT/redmine.pgdump.part"
[ "$(head -c 5 "$OUT/redmine.pgdump.part")" = "PGDMP" ] || die "invalid dump received"
mv "$OUT/redmine.pgdump.part" "$OUT/redmine.pgdump"

step "Attachments (volume $FILES_VOLUME)"
remote "docker run --rm -v $FILES_VOLUME:/data:ro busybox:stable tar -czf - -C /data ." > "$OUT/redmine-files.tar.gz.part"
gzip -t "$OUT/redmine-files.tar.gz.part" || die "invalid attachments archive received"
mv "$OUT/redmine-files.tar.gz.part" "$OUT/redmine-files.tar.gz"

step "Manifest"
q() { remote "docker exec $DB_CONTAINER psql -U $DB_USER -d $DB_NAME -tA -c \"$1\""; }
{
  echo "date:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host:      $HOST"
  echo "postgres:  $(q 'SHOW server_version')"
  echo "schema:    $(q 'SELECT max(version) FROM schema_migrations WHERE version NOT LIKE '"'"'%-%'"'"'')"
  echo "issues:    $(q 'SELECT count(*) FROM issues')"
  echo "attachments rows: $(q 'SELECT count(*) FROM attachments')"
  echo "attachment files: $(tar -tzf "$OUT/redmine-files.tar.gz" | grep -vc '/$')"
  echo "sha256:"
  (cd "$OUT" && sha256sum redmine.pgdump redmine-files.tar.gz | sed 's/^/  /')
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
step "Done: $OUT"
